defmodule LiveQuiz.Games.History do
  @moduledoc """
  What is left of a match once it is over.

  Finishing a room freezes one `LiveQuiz.Games.GameResult` per participation —
  score, counts, position and the questions as they were played — and from then
  on nothing here reads the live tables. That is the point: a result keeps
  answering after the quiz has been edited and after it has been deleted,
  because it carries its own copy of everything it shows.

  ## What durability means here, exactly

  It is durability against **editing and deleting the quiz**, and that is what
  the schema buys: `quiz_id` is nullified and the title, the statements and the
  alternatives were copied at the time.

  It is *not* durability against deleting the match or the participation. Those
  two references cascade, so removing a `game_sessions` or a `participants` row
  removes the results hanging from it — and removing an account removes the
  rooms it hosted, and with them everybody else's results from those rooms.

  Nothing in the application deletes any of those today: there is no purge and
  no account deletion. The reason to write it down is that the first feature to
  do either will decide, by accident, what happens to history — and it should
  decide it on purpose. Retention and anonymisation are the question, not
  whether a foreign key cascades, and blocking the deletion of personal data in
  the name of history is not the answer either.

  Who may read what is decided per row rather than per endpoint, because the
  same result is legitimately readable by three different people: the host of
  the match, the participation it belongs to, and the account that
  participation was tied to. `result_visible_to?/2` is the whole rule, and a
  refusal is a `:not_found` — a result someone may not read is
  indistinguishable from one that does not exist.

  The listings take their filters already read by `LiveQuiz.Games.ResultFilters`
  and their pagination by `LiveQuiz.Pagination`, so a day means the same thing
  here as it does over HTTP.
  """

  import Ecto.Query

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games.GameResult
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.ResultFilters
  alias LiveQuiz.Pagination
  alias LiveQuiz.Repo

  @doc """
  Fetches one immutable result for its host or for the participant it belongs to.

  A participant can never use its identity to read another participant's result;
  callers that are not part of the match receive the same not-found response as
  an unknown result.
  """
  @spec get_game_result(Scope.t() | Participant.t() | nil, integer(), integer()) ::
          {:ok, GameResult.t()} | {:error, :not_found}
  def get_game_result(identity, session_id, participant_id)
      when is_integer(session_id) and is_integer(participant_id) do
    query =
      from r in GameResult,
        where: r.game_session_id == ^session_id and r.participant_id == ^participant_id,
        preload: [:game_session, :participant]

    case Repo.one(query) do
      %GameResult{} = result ->
        if result_visible_to?(result, identity), do: {:ok, result}, else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Fetches a participant's own result by its stable result identifier."
  @spec get_my_game_result(Scope.t(), integer() | String.t()) ::
          {:ok, GameResult.t()} | {:error, :not_found}
  def get_my_game_result(%Scope{} = scope, id) do
    query =
      from r in GameResult,
        where: r.id == ^id and r.user_id == ^scope.user.id,
        preload: [:game_session, :participant]

    case Repo.one(query) do
      %GameResult{} = result -> {:ok, result}
      nil -> {:error, :not_found}
    end
  end

  @doc "Fetches the authenticated user's result for a finished match."
  @spec get_my_game_result_for_session(Scope.t(), integer()) ::
          {:ok, GameResult.t()} | {:error, :not_found}
  def get_my_game_result_for_session(%Scope{} = scope, session_id)
      when is_integer(session_id) do
    query =
      from r in GameResult,
        where: r.game_session_id == ^session_id and r.user_id == ^scope.user.id,
        join: s in assoc(r, :game_session),
        where: s.status == :finished,
        preload: [:game_session, :participant]

    case Repo.one(query) do
      %GameResult{} = result -> {:ok, result}
      nil -> {:error, :not_found}
    end
  end

  @doc "Lists the finished results belonging to the authenticated participant."
  @spec list_game_results(Scope.t(), map() | keyword(), map() | keyword()) :: map()
  def list_game_results(%Scope{} = scope, filters, pagination) do
    query =
      from r in GameResult,
        join: s in assoc(r, :game_session),
        where: r.user_id == ^scope.user.id and s.status == :finished

    query
    |> result_filters(filters)
    |> paginate_results(pagination)
  end

  @doc "Lists finished matches hosted for quizzes owned by the authenticated user."
  @spec list_quiz_game_history(Scope.t(), integer(), map() | keyword(), map() | keyword()) ::
          map()
  def list_quiz_game_history(%Scope{} = scope, quiz_id, filters, pagination)
      when is_integer(quiz_id) do
    query =
      from s in GameSession,
        left_join: q in assoc(s, :quiz),
        where: s.host_id == ^scope.user.id and s.quiz_id == ^quiz_id and s.status == :finished,
        left_join: r in assoc(s, :game_results),
        group_by: [s.id, q.id],
        select: %{
          session: s,
          quiz_title: s.quiz_title,
          participants_count: count(r.id),
          winner_nickname:
            fragment("(array_agg(? ORDER BY ? ASC))[1]", r.nickname, r.final_position),
          winner_score: fragment("(array_agg(? ORDER BY ? ASC))[1]", r.score, r.final_position)
        }

    query
    |> session_result_filters(filters)
    |> paginate_sessions(pagination)
  end

  @doc "Lists every finished match hosted by quizzes owned by the user."
  @spec list_host_game_history(Scope.t(), map() | keyword(), map() | keyword()) :: map()
  def list_host_game_history(%Scope{} = scope, filters, pagination) do
    query =
      from s in GameSession,
        left_join: q in assoc(s, :quiz),
        where: s.host_id == ^scope.user.id and s.status == :finished,
        left_join: r in assoc(s, :game_results),
        group_by: [s.id, q.id],
        select: %{
          session: s,
          quiz_title: s.quiz_title,
          participants_count: count(r.id),
          winner_nickname:
            fragment("(array_agg(? ORDER BY ? ASC))[1]", r.nickname, r.final_position),
          winner_score: fragment("(array_agg(? ORDER BY ? ASC))[1]", r.score, r.final_position)
        }

    query
    |> session_result_filters(filters)
    |> paginate_sessions(pagination)
  end

  @doc "Fetches a finished match and its complete host-visible ranking."
  @spec get_host_game_history(Scope.t(), integer() | String.t()) ::
          {:ok, GameSession.t()} | {:error, :not_found}
  def get_host_game_history(%Scope{} = scope, id) do
    results_query = from r in GameResult, order_by: [asc: r.final_position]

    query =
      from s in GameSession,
        where: s.id == ^id and s.host_id == ^scope.user.id and s.status == :finished,
        preload: [game_results: ^results_query]

    case Repo.one(query) do
      %GameSession{} = session -> {:ok, session}
      nil -> {:error, :not_found}
    end
  end

  @doc "Fetches one immutable participant result for the host of its match."
  @spec get_host_game_result(Scope.t(), integer() | String.t()) ::
          {:ok, GameResult.t()} | {:error, :not_found}
  def get_host_game_result(%Scope{} = scope, id) do
    query =
      from r in GameResult,
        join: s in assoc(r, :game_session),
        where: r.id == ^id and s.host_id == ^scope.user.id and s.status == :finished,
        preload: [:game_session, :participant]

    case Repo.one(query) do
      %GameResult{} = result -> {:ok, result}
      nil -> {:error, :not_found}
    end
  end

  defp result_visible_to?(%GameResult{game_session: %GameSession{host_id: host_id}}, %Scope{
         user: %User{id: host_id}
       }),
       do: true

  defp result_visible_to?(%GameResult{participant_id: participant_id}, %Participant{
         id: participant_id
       }),
       do: true

  defp result_visible_to?(%GameResult{user_id: user_id}, %Scope{user: %User{id: user_id}}),
    do: true

  defp result_visible_to?(_result, _identity), do: false

  # The three filters are read by `LiveQuiz.Games.ResultFilters`, which is where
  # a bare date becomes a whole day. Everything that arrives here is already a
  # `DateTime` or `nil`, so a listing cannot disagree with the API about which
  # rows a day contains.
  defp result_filters(query, filters) do
    filters = ResultFilters.normalize(filters)

    query
    |> maybe_filter_quiz(filters.quiz_id)
    |> maybe_filter_date(filters.from, :>=)
    |> maybe_filter_date(filters.to, :<=)
  end

  defp session_result_filters(query, filters) do
    filters = ResultFilters.normalize(filters)

    query
    |> maybe_filter_session_quiz(filters.quiz_id)
    |> maybe_filter_session_date(filters.from, :>=)
    |> maybe_filter_session_date(filters.to, :<=)
  end

  defp maybe_filter_session_quiz(query, nil), do: query

  defp maybe_filter_session_quiz(query, quiz_id),
    do: where(query, [s, _q, _r], s.quiz_id == ^quiz_id)

  defp maybe_filter_quiz(query, nil), do: query
  defp maybe_filter_quiz(query, quiz_id), do: where(query, [r, _s], r.quiz_id == ^quiz_id)

  defp maybe_filter_date(query, nil, _operator), do: query

  defp maybe_filter_date(query, %DateTime{} = at, :>=),
    do: where(query, [r, _s], r.inserted_at >= ^at)

  defp maybe_filter_date(query, %DateTime{} = at, :<=),
    do: where(query, [r, _s], r.inserted_at <= ^at)

  defp maybe_filter_session_date(query, nil, _operator), do: query

  defp maybe_filter_session_date(query, %DateTime{} = at, :>=),
    do: where(query, [s, _q, r], coalesce(s.finished_at, r.inserted_at) >= ^at)

  defp maybe_filter_session_date(query, %DateTime{} = at, :<=),
    do: where(query, [s, _q, r], coalesce(s.finished_at, r.inserted_at) <= ^at)

  defp paginate_results(query, pagination) do
    %{page: page, per_page: per_page} = Pagination.normalize(pagination)

    total = Repo.aggregate(query, :count, :id)

    %{
      entries:
        Repo.all(
          from r in query,
            order_by: [desc: r.inserted_at, desc: r.id],
            limit: ^per_page,
            offset: ^((page - 1) * per_page)
        ),
      page: page,
      per_page: per_page,
      total_entries: total,
      total_pages: ceil(total / per_page)
    }
  end

  defp paginate_sessions(query, pagination) do
    %{page: page, per_page: per_page} = Pagination.normalize(pagination)

    # One row per match comes back, so the total is how many distinct matches the
    # filters left — asked of the database. Reading every row back only to call
    # `length/1` on it costs the whole history on every request, and the page
    # below already discards all but `per_page` of them.
    total =
      query
      |> exclude(:select)
      |> exclude(:group_by)
      |> exclude(:order_by)
      |> select([s, _q, _r], count(s.id, :distinct))
      |> Repo.one()

    entries =
      query
      |> order_by([s, _q, _r], desc: s.finished_at, desc: s.id)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      entries: entries,
      page: page,
      per_page: per_page,
      total_entries: total,
      total_pages: ceil(total / per_page)
    }
  end
end
