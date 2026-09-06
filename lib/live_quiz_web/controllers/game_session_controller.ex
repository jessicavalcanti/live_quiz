defmodule LiveQuizWeb.GameSessionController do
  @moduledoc """
  Opens the room the "Iniciar partida" button of the dashboard asks for.

  Creating a room is not a screen (F2-08): the button posts here, the context
  decides, and the answer is always a redirect — to the lobby of the brand new
  room, or back to the dashboard carrying the reason it was refused.

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
  Forgets the credential of one room, leaving the credentials of the others.

  Only the browser side of leaving: the participation is closed by the lobby
  (F2-10), which is what frees the person to enter somewhere else. Dropping the
  credential here is what stops the join screen from taking them back into the
  room they just walked out of.

  Leaving is not an ending, so the join screen is where it lands, with the
  reason said out loud: whoever clicked "Sair da sala" has to read that it
  worked instead of guessing it from a form that came back empty.
  """
  def leave(conn, %{"code" => code}) do
    conn
    |> ParticipantAuth.drop_token(code)
    |> put_flash(:info, "Você saiu da sala. Entre em outra quando quiser.")
    |> redirect(to: ~p"/join")
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
