defmodule LiveQuizWeb.Api.FallbackController do
  @moduledoc """
  Translates the error tuples returned by the contexts into HTTP responses.

  Every controller of the API plugs this module with `action_fallback`, so the
  error envelope is written once and reused by every endpoint.
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

  def call(conn, {:error, :invalid_direction}) do
    error(conn, :unprocessable_entity, ~s(A direção deve ser "up" ou "down"))
  end

  def call(conn, {:error, :invalid_credentials}) do
    error(conn, :unauthorized, "E-mail ou senha inválidos")
  end

  def call(conn, {:error, :invalid_refresh_token}) do
    error(conn, :unauthorized, "Refresh token inválido ou expirado")
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> json(ErrorJSON.render("401.json", %{}))
  end

  def call(conn, {:error, :not_found}) do
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
