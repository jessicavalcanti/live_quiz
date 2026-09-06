defmodule LiveQuizWeb.Api.AuthPipeline do
  @moduledoc """
  Authentication pipeline of the JSON API.

  Reads the `Authorization: Bearer <token>` header, requires the token to be a
  valid **access** token (the `typ` claim is checked, so a refresh token is not
  accepted here), loads the user and assigns the scope.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :live_quiz,
    module: LiveQuiz.Accounts.Guardian,
    error_handler: LiveQuizWeb.Api.AuthErrorHandler

  plug Guardian.Plug.VerifyHeader, scheme: "Bearer", claims: %{"typ" => "access"}
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource
  plug LiveQuizWeb.Api.AssignScope
end
