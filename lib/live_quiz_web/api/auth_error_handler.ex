defmodule LiveQuizWeb.Api.AuthErrorHandler do
  @moduledoc """
  Turns every Guardian authentication failure into the same `401`.

  A missing header, a malformed token, an expired one and a refresh token used
  as an access token are indistinguishable from the outside: they all answer
  `{"errors": {"detail": "Não autenticado"}}`.
  """

  @behaviour Guardian.Plug.ErrorHandler

  alias LiveQuizWeb.Api.ErrorJSON

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {_type, _reason}, _opts) do
    conn
    |> Plug.Conn.put_status(:unauthorized)
    |> Phoenix.Controller.json(ErrorJSON.render("401.json", %{}))
    |> Plug.Conn.halt()
  end
end
