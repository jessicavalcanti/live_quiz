defmodule LiveQuizWeb.Api.FallbackController do
  @moduledoc """
  Translates the error tuples returned by the contexts into HTTP responses.

  Every controller of the API plugs this module with `action_fallback`, so the
  error envelope is written once and reused by every endpoint.

  The status is picked by what the refusal means, never by convenience. `409`
  is a conflict with the state of a room — it is full, the nickname is taken,
  the person is already somewhere else — and says that trying again unchanged
  will not help. `422` is a value that could have been right and was not. `403`
  is somebody identified who may not do this, while `401` is somebody the server
  could not identify at all. `404` covers what does not exist **and** what must
  not be revealed to exist (AD-10). `410` is kept for the one refusal that is
  neither of those: the room was there and is over.
  """

  use Phoenix.Controller, formats: [:json]

  alias LiveQuiz.Quizzes
  alias LiveQuizWeb.Api.ErrorJSON

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorJSON.render("changeset.json", %{changeset: changeset}))
  end

  def call(conn, {:error, :question_limit_reached}) do
    error(
      conn,
      :unprocessable_entity,
      "Este quiz já atingiu o limite de #{Quizzes.max_questions()} perguntas"
    )
  end

  def call(conn, {:error, :quiz_locked}) do
    error(conn, :conflict, "Este quiz possui uma sala ativa e não pode ser alterado")
  end

  def call(conn, {:error, :invalid_direction}) do
    error(conn, :unprocessable_entity, ~s(A direção deve ser "up" ou "down"))
  end

  def call(conn, {:error, :invalid_credentials}) do
    error(conn, :unauthorized, "E-mail ou senha inválidos")
  end

  def call(conn, {:error, :invalid_refresh_token}) do
    error(conn, :unauthorized, "Refresh token inválido ou expirado")
  end

  def call(conn, {:error, :quiz_not_playable}) do
    error(conn, :unprocessable_entity, "O quiz precisa ter ao menos uma pergunta")
  end

  def call(conn, {:error, :host_already_in_session}) do
    error(conn, :conflict, "Você já possui uma sala ativa")
  end

  def call(conn, {:error, :already_participating}) do
    error(conn, :conflict, "Saia da sala em que você está para abrir uma nova")
  end

  def call(conn, {:error, :code_generation_failed}) do
    error(conn, :service_unavailable, "Não foi possível gerar um código. Tente novamente.")
  end

  def call(conn, {:error, :session_not_joinable}) do
    error(conn, :conflict, "Esta partida já começou")
  end

  def call(conn, {:error, :session_full}) do
    error(conn, :conflict, "Sala lotada")
  end

  def call(conn, {:error, :nickname_taken}) do
    error(conn, :conflict, "Este apelido já está em uso nesta sala")
  end

  def call(conn, {:error, :already_in_another_session}) do
    error(conn, :conflict, "Você já está participando de outra sala")
  end

  def call(conn, {:error, :no_connected_participants}) do
    error(conn, :conflict, "É preciso ao menos um participante conectado")
  end

  def call(conn, {:error, :invalid_transition}) do
    error(conn, :conflict, "Esta sala já foi encerrada")
  end

  def call(conn, {:error, :session_ended}) do
    error(conn, :gone, "Esta sala foi encerrada")
  end

  # Somebody the request did identify, acting where they may not: the host of
  # another room, or a credential asking for a lobby that is not its own.
  def call(conn, {:error, :unauthorized}) do
    error(conn, :forbidden, "Acesso negado")
  end

  # Nobody the request could identify — no credential, or one that buys nothing.
  def call(conn, {:error, :unauthenticated}) do
    conn
    |> put_status(:unauthorized)
    |> json(ErrorJSON.render("401.json", %{}))
  end

  def call(conn, {:error, reason}) when reason in [:not_found, :session_not_found] do
    conn
    |> put_status(:not_found)
    |> json(ErrorJSON.render("404.json", %{}))
  end

  defp error(conn, status, detail) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("error.json", %{detail: detail}))
  end
end
