defmodule LiveQuizWeb.Api.V1.Schemas.SessionRequest do
  @moduledoc """
  Documents the credentials exchanged for a pair of tokens.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "SessionRequest",
      description: "Credenciais de acesso do usuário.",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email, description: "E-mail cadastrado"},
        password: %Schema{type: :string, format: :password, description: "Senha do usuário"}
      },
      required: [:email, :password],
      example: %{"email" => "voce@example.com", "password" => "sua-senha-secreta"}
    },
    struct?: false,
    derive?: false
  )
end
