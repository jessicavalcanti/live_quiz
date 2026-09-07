defmodule LiveQuizWeb.GameSessionController do
  @moduledoc """
  Opens the room the "Iniciar partida" button of the dashboard asks for.

  Creating a room takes no screen of its own (F2-08): a post lands here, the
  context decides, and the answer is always a redirect — to the lobby of the
  brand new room, or back to the dashboard carrying the reason it was refused.
  Since F3-07 the dashboard asks for the duration of the questions before
  opening the room, and creates it from the LiveView itself; this action stays
  as the plain browser path, which opens a room with the default duration.

  A host who already has a live room is the one case that is not an error to
  read: they are taken to the room they already have, which is the same thing
  the dashboard notice offers. A quiz that belongs to somebody else never gets
  this far — the context raises and the request ends as a 404.
  """
  use LiveQuizWeb, :controller

  alias LiveQuiz.Games
  alias LiveQuiz.Games.JoinCode
  alias LiveQuizWeb.ParticipantAuth

  def create(conn, %{"quiz_id" => quiz_id}) do
    scope = conn.assigns.current_scope

    case Games.create_game_session(scope, quiz_id) do
      {:ok, session} ->
        redirect(conn, to: ~p"/game-sessions/#{session.join_code}/host")

      {:error, :host_already_in_session} ->
        resume_active_session(conn, scope)

      {:error, reason} ->
        conn
        |> put_flash(:error, message(reason))
        |> redirect(to: ~p"/quizzes")
    end
  end

  @doc """
  Writes the credential the join screen just obtained and opens the lobby.

  A LiveView cannot set a cookie, so the entry itself happens in
  `LiveQuizWeb.GameSessionLive.Join` and only the last step lands here: the
  screen posts the code and the clear token once, this action stores them and
  redirects. The token never becomes part of the address it redirects to, which
  would leave the credential sitting in the browser history.

  It stores what it is given without asking whether it is real. A token that
  buys nothing simply fails to open a lobby, and refusing it here would only
  duplicate a check the lobby has to make anyway.
  """
  def join(conn, %{"code" => code, "token" => token}) when is_binary(token) do
    normalized = JoinCode.normalize(code)

    conn
    |> ParticipantAuth.put_token(normalized, token)
    |> redirect(to: lobby_path(normalized))
  end

  def join(conn, _params) do
    conn
    |> put_flash(:error, "Não foi possível entrar na sala. Tente novamente.")
    |> redirect(to: ~p"/join")
  end

  @doc """
  Leaves the room, and remembers the way back.

  Both halves of leaving happen here now. The transition used to be the lobby's
  alone (F2-10) and this action only dropped the cookie, so a request that
  arrived without the LiveView event before it — a direct `DELETE`, a retry, a
  tab closed mid-flight — forgot the credential while the participation stayed
  open. `LiveQuiz.Games.leave_game_session/1` is idempotent, so running it here
  as well costs nothing when the lobby already did it and is the whole
  transition when it did not.

  The credential is **kept**, marked as a room this browser walked out of. The
  domain holds the participation and the nickname for a return, and for a guest
  that token is the only thing that can prove who they were; erasing it locked
  them out of a room the context was still holding open (R26). What changes is
  that the join screen stops walking back into it on its own.

  Leaving is not an ending, so the join screen is where it lands, with the
  reason said out loud: whoever clicked "Sair da sala" has to read that it
  worked instead of guessing it from a form that came back empty.
  """
  def leave(conn, %{"code" => code}) do
    conn
    |> leave_participation(code)
    |> ParticipantAuth.mark_left(code)
    |> put_flash(:info, "Você saiu da sala. Pode voltar por ela ou entrar em outra.")
    |> redirect(to: ~p"/join")
  end

  defp leave_participation(conn, code) do
    token = conn |> ParticipantAuth.read_tokens() |> Map.get(JoinCode.normalize(code))

    with token when is_binary(token) <- token,
         {:ok, participant} <- Games.get_participant_of_session(token, code) do
      {:ok, _left} = Games.leave_game_session(participant)
    end

    conn
  end

  defp lobby_path(code), do: ~p"/game-sessions/#{code}"

  # The room may have been closed between the refusal and this read, in which
  # case there is nowhere to send the host: the dashboard, with the reason, is
  # the honest answer.
  defp resume_active_session(conn, scope) do
    case Games.get_active_session_for_host(scope) do
      nil ->
        conn
        |> put_flash(:error, message(:host_already_in_session))
        |> redirect(to: ~p"/quizzes")

      session ->
        conn
        |> put_flash(:info, "Você já tem uma sala aberta. Continue por ela.")
        |> redirect(to: ~p"/game-sessions/#{session.join_code}/host")
    end
  end

  defp message(:quiz_not_playable),
    do: "Adicione ao menos uma pergunta antes de iniciar uma partida"

  defp message(:already_participating),
    do: "Saia da sala em que você está antes de abrir a sua"

  defp message(:host_already_in_session), do: "Você já tem uma sala aberta"

  defp message(_reason), do: "Não foi possível abrir a sala. Tente novamente."
end
