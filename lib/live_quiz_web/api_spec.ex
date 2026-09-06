defmodule LiveQuizWeb.ApiSpec do
  @moduledoc """
  Builds the OpenAPI 3 specification of the JSON API.

  The document is derived at runtime from the router and from the `operation/2`
  annotations of the controllers, never from a handwritten YAML file: a route or
  a payload that changes without its annotation being updated shows up in the
  contract test instead of drifting silently.

  Every endpoint is authenticated by the `bearerAuth` scheme declared here,
  except login and refresh, which override it with an empty requirement.
  """

  alias LiveQuizWeb.Endpoint
  alias LiveQuizWeb.Router
  alias OpenApiSpex.Components
  alias OpenApiSpex.Info
  alias OpenApiSpex.OpenApi
  alias OpenApiSpex.Paths
  alias OpenApiSpex.SecurityScheme
  alias OpenApiSpex.Server
  alias OpenApiSpex.Tag

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Live Quiz API",
        version: "1.0.0",
        description: "API da plataforma de quizzes em tempo real"
      },
      servers: [Server.from_endpoint(Endpoint)],
      paths: Paths.from_router(Router),
      tags: tags(),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT",
            description: "Token de acesso obtido em POST /api/v1/session"
          }
        }
      },
      security: [%{"bearerAuth" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end

  defp tags do
    [
      %Tag{name: "Sessão", description: "Autenticação, renovação de token e usuário autenticado"},
      %Tag{name: "Quizzes", description: "Criação e gerenciamento dos quizzes do usuário"},
      %Tag{name: "Perguntas", description: "Perguntas de um quiz e suas alternativas"}
    ]
  end
end
