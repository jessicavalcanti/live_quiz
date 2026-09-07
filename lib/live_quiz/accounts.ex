defmodule LiveQuiz.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias LiveQuiz.Mail
  alias LiveQuiz.Repo

  # How recently somebody has to have proved their password before the
  # application will let them change it or change their e-mail. One number,
  # because two of them is a validity nobody can predict: the settings page used
  # to be mounted under a ten minute window and its events checked against a
  # twenty minute one, so a tab could be refused entry and still be allowed to
  # act (R06).
  @sudo_window_minutes 10

  alias LiveQuiz.Accounts.{RefreshToken, User, UserNotifier, UserToken}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  # A form posts strings; a request written by hand can post a map, a list or
  # nothing at all. That is a credential nobody could have, not a reason to
  # raise a `FunctionClauseError` and answer 500 (R06). It still runs the same
  # dummy hash the miss above runs, so an unusable shape and a wrong password
  # take the same time to be refused.
  def get_user_by_email_and_password(_email, _password) do
    User.valid_password?(nil, nil)

    nil
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a single user, or `nil` when there is no user with the given id.

  Unlike `get_user!/1` this never raises, which is what the API token
  verification needs: a token whose subject no longer exists is just an
  unauthenticated request, not a crash.

  ## Examples

      iex> get_user(123)
      %User{}

      iex> get_user(456)
      nil

  """
  def get_user(id) when is_integer(id), do: Repo.get(User, id)

  def get_user(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer_id, ""} -> get_user(integer_id)
      _other -> nil
    end
  end

  def get_user(_id), do: nil

  @credentials_types %{email: :string, password: :string}

  @doc """
  Authenticates a set of e-mail and password credentials coming from the API.

  Returns `{:error, changeset}` when a field is missing, so the caller can answer
  422, and `{:error, :invalid_credentials}` for both a wrong password and an
  unknown e-mail — the same answer either way, so the API never reveals whether
  an address is registered.

  ## Examples

      iex> authenticate_by_credentials(%{"email" => "foo@example.com", "password" => "correct"})
      {:ok, %User{}}

      iex> authenticate_by_credentials(%{"email" => "foo@example.com", "password" => "wrong"})
      {:error, :invalid_credentials}

      iex> authenticate_by_credentials(%{"email" => "foo@example.com"})
      {:error, %Ecto.Changeset{}}

  """
  @spec authenticate_by_credentials(map()) ::
          {:ok, User.t()} | {:error, :invalid_credentials} | {:error, Ecto.Changeset.t()}
  def authenticate_by_credentials(params) when is_map(params) do
    changeset =
      {%{}, @credentials_types}
      |> Ecto.Changeset.cast(params, Map.keys(@credentials_types))
      |> Ecto.Changeset.validate_required([:email, :password])

    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, credentials} -> authenticate(credentials)
      {:error, invalid_changeset} -> {:error, invalid_changeset}
    end
  end

  def authenticate_by_credentials(_params), do: {:error, :invalid_credentials}

  defp authenticate(%{email: email, password: password}) do
    case get_user_by_email_and_password(email, password) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :invalid_credentials}
    end
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user registration changes.

  See `LiveQuiz.Accounts.User.registration_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_registration(%User{})
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false, validate_unique: false)
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -@sudo_window_minutes)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc "How long a password stays freshly proved, in minutes."
  @spec sudo_window_minutes() :: pos_integer()
  def sudo_window_minutes, do: @sudo_window_minutes

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `LiveQuiz.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    record_token_email(user, "change:#{current_email}", update_email_url_fun, fn url ->
      {"update_email", UserNotifier.update_email_instructions(user, url)}
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `LiveQuiz.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  ## Confirmation

  @doc ~S"""
  Delivers the confirmation instructions to the given user.

  Returns `{:error, :already_confirmed}` when the account is already confirmed.

  ## Examples

      iex> deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      record_token_email(user, "confirm", confirmation_url_fun, fn url ->
        {"confirmation", UserNotifier.confirmation_instructions(user, url)}
      end)
    end
  end

  @doc """
  Confirms a user by the given token.

  If the token matches, the user account is marked as confirmed and the token
  is deleted. The session tokens are kept, so confirming never logs the user out.
  """
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, user} <- confirm_user_and_delete_tokens(user) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp confirm_user_and_delete_tokens(user) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(User.confirm_changeset(user)) do
        Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["confirm"]))
        {:ok, user}
      end
    end)
  end

  ## Reset password

  @doc ~S"""
  Delivers the reset password instructions to the given user.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &url(~p"/users/reset-password/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    record_token_email(user, "reset_password", reset_password_url_fun, fn url ->
      {"reset_password", UserNotifier.reset_password_instructions(user, url)}
    end)
  end

  # The token and the intent to mail it are written in one transaction, so the
  # two facts cannot disagree: there is no token whose message was never owed,
  # and no message owed for a token that does not exist (R07). Sending is not
  # part of it — that is exactly what was wrong before.
  defp record_token_email(%User{} = user, context, url_fun, render) do
    {encoded_token, user_token} = UserToken.build_email_token(user, context)
    {kind, message} = render.(url_fun.(encoded_token))

    result =
      Repo.transact(fn ->
        token = Repo.insert!(user_token)

        Mail.record(%{
          user_id: user.id,
          recipient: user.email,
          subject: message.subject,
          body: message.body,
          kind: kind,
          # One intent per token. A caller that runs twice writes one message;
          # a genuinely new request mints a new token and is a new message.
          dedupe_key: Base.encode16(token.token, case: :lower),
          expires_at: expiry_of(context)
        })
      end)

    with {:ok, delivery} <- result do
      Mail.deliver_soon()

      {:ok, delivery}
    end
  end

  # The message is worth sending exactly as long as the link works.
  defp expiry_of(context) do
    DateTime.add(DateTime.utc_now(:second), UserToken.validity_in_days(context), :day)
  end

  @doc """
  Gets the user by the given reset password token.

  Returns `nil` when the token is invalid or has expired.
  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Resets the password of the user the reset token belongs to.

  The token is the authorization for this write, so it is re-checked here
  rather than by the caller: a link validated when a page was opened says
  nothing about whether it is still valid now, and a second tab holding the
  same link must not be able to set the password again after the first one
  consumed it.

  Everything happens in one transaction. The user row is taken `FOR UPDATE`
  first, so two resets of the same account queue up instead of racing, and the
  token is only re-read once that lock is held — a competitor that got there
  first has already deleted it by then, and this call answers
  `{:error, :invalid_token}`.

  An invalid password does not spend a valid token: the changeset error rolls
  the transaction back, leaving the link usable for the next attempt.

  Returns the updated user with every token that was expired. Those tokens
  still authorize LiveViews that mounted before the reset, so the caller has to
  pass them to `LiveQuizWeb.UserAuth.disconnect_sessions/1` after this returns
  — deleting the rows only stops the *next* HTTP authentication.

  ## Examples

      iex> reset_user_password(token, %{password: "new long password"})
      {:ok, {%User{}, [...]}}

      iex> reset_user_password(token, %{password: "short"})
      {:error, %Ecto.Changeset{}}

      iex> reset_user_password("already used", %{password: "new long password"})
      {:error, :invalid_token}

  """
  def reset_user_password(token, attrs) when is_binary(token) do
    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
           %User{id: user_id} <- Repo.one(query),
           %User{} <- lock_user(user_id),
           %User{} = user <- Repo.one(query),
           {:ok, {updated, expired}} <-
             user |> User.password_changeset(attrs) |> update_user_and_delete_all_tokens() do
        # Web sessions end by having their rows deleted above. API sessions
        # prove themselves from a signature, so they end here: the refresh
        # families are revoked and the auth version moves, which rejects every
        # access token already issued (R03). Resetting a password is the one
        # action that has to mean "everywhere, now".
        {:ok, _revoked} = revoke_all_api_sessions(updated)

        {:ok, {updated, expired}}
      else
        {:error, %Ecto.Changeset{}} = invalid_password -> invalid_password
        _ -> {:error, :invalid_token}
      end
    end)
  end

  defp lock_user(user_id) do
    User |> where([u], u.id == ^user_id) |> lock("FOR UPDATE") |> Repo.one()
  end

  ## API sessions

  @doc """
  Opens a refresh family for a freshly authenticated account.

  One family per login. The token itself is not stored — only its digest — and
  the row is what makes revoking a session possible at all: a JWT proves itself
  from its signature, so without this there is nothing to say "not this one any
  more" (R03).
  """
  @spec start_refresh_family(User.t(), String.t(), DateTime.t()) ::
          {:ok, RefreshToken.t()} | {:error, Ecto.Changeset.t()}
  def start_refresh_family(%User{} = user, token, %DateTime{} = expires_at) do
    %RefreshToken{}
    |> RefreshToken.changeset(%{
      user_id: user.id,
      family_id: Ecto.UUID.generate(),
      token_hash: RefreshToken.hash(token),
      expires_at: DateTime.truncate(expires_at, :second)
    })
    |> Repo.insert()
  end

  @doc """
  Spends a refresh token and issues the next one of its family.

  Rotation is what turns a long-lived secret into a chain, and the chain is
  what makes replay visible. A row spent twice means two holders, and only one
  of them logged in — so the whole family is revoked rather than guessing which:
  the thief loses the session, and so does the person, who logs in again and
  learns something happened. That is the trade the reuse detection makes, and it
  is the right way round.

  Answers `{:error, :invalid_refresh_token}` for a token that is unknown, spent,
  revoked or expired, which are all the same news to the client.
  """
  @spec rotate_refresh_token(String.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :invalid_refresh_token}
  def rotate_refresh_token(presented, issued, %DateTime{} = expires_at) do
    now = DateTime.utc_now(:second)

    # The refusal is carried out as a value rather than as `{:error, _}`:
    # rejecting a replay is a *write* — the family is revoked — and rolling the
    # transaction back would undo exactly the thing the detection is for.
    result =
      Repo.transact(fn ->
        presented
        |> RefreshToken.hash()
        |> lock_refresh_token()
        |> spend_or_revoke(issued, expires_at, now)
      end)

    case result do
      {:ok, :rotated} -> :ok
      _refused -> {:error, :invalid_refresh_token}
    end
  end

  defp spend_or_revoke(nil, _issued, _expires_at, _now), do: {:ok, :unknown}

  defp spend_or_revoke(%RefreshToken{} = token, issued, expires_at, now) do
    if RefreshToken.spendable?(token, now) do
      spend(token, issued, expires_at, now)
    else
      # Spent, revoked or expired. Revoking the family covers the case that
      # matters: a token presented twice is a token somebody else also has.
      revoke_family(token, now)

      {:ok, :reused}
    end
  end

  @doc """
  Revokes the family a refresh token belongs to — logging out one device.

  Idempotent, and deliberately quiet about tokens it does not recognise: a
  client discarding a credential it can no longer use should not be told
  whether the server had ever heard of it.
  """
  @spec revoke_refresh_family(String.t()) :: :ok
  def revoke_refresh_family(token) when is_binary(token) do
    now = DateTime.utc_now(:second)

    case Repo.get_by(RefreshToken, token_hash: RefreshToken.hash(token)) do
      nil -> :ok
      %RefreshToken{} = found -> revoke_family(found, now)
    end
  end

  def revoke_refresh_family(_token), do: :ok

  @doc """
  Ends every API session of an account, on every device.

  Two writes, because a session has two halves. The refresh families go, so
  nothing can be renewed; and `auth_version` moves, which rejects every access
  token already issued — immediately, without a lookup per request, because the
  account row is read to resolve the subject either way.
  """
  @spec revoke_all_api_sessions(User.t()) :: {:ok, User.t()}
  def revoke_all_api_sessions(%User{} = user) do
    now = DateTime.utc_now(:second)

    Repo.update_all(
      from(t in RefreshToken, where: t.user_id == ^user.id and is_nil(t.revoked_at)),
      set: [revoked_at: now, updated_at: now]
    )

    {1, [updated]} =
      Repo.update_all(
        from(u in User, where: u.id == ^user.id, select: u),
        inc: [auth_version: 1],
        set: [updated_at: now]
      )

    {:ok, updated}
  end

  defp lock_refresh_token(hash) do
    RefreshToken
    |> where([t], t.token_hash == ^hash)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp spend(%RefreshToken{} = token, issued, expires_at, now) do
    {1, _} =
      Repo.update_all(
        from(t in RefreshToken, where: t.id == ^token.id),
        set: [used_at: now, updated_at: now]
      )

    %RefreshToken{}
    |> RefreshToken.changeset(%{
      user_id: token.user_id,
      family_id: token.family_id,
      token_hash: RefreshToken.hash(issued),
      expires_at: DateTime.truncate(expires_at, :second)
    })
    |> Repo.insert()
    |> case do
      {:ok, _next} -> {:ok, :rotated}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp revoke_family(%RefreshToken{} = token, now) do
    Repo.update_all(
      from(t in RefreshToken, where: t.family_id == ^token.family_id and is_nil(t.revoked_at)),
      set: [revoked_at: now, updated_at: now]
    )

    :ok
  end

  ## Session

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  # Callers already inside a transaction — `reset_user_password/2` — get the
  # same guarantee without opening a nested one, which Ecto would flatten anyway.
  defp update_user_and_delete_all_tokens(changeset) do
    if Repo.in_transaction?() do
      expire_tokens_of_updated_user(changeset)
    else
      Repo.transact(fn -> expire_tokens_of_updated_user(changeset) end)
    end
  end

  defp expire_tokens_of_updated_user(changeset) do
    with {:ok, user} <- Repo.update(changeset) do
      tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

      Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

      {:ok, {user, tokens_to_expire}}
    end
  end
end
