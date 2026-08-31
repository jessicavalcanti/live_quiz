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
