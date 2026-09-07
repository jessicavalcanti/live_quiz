defmodule LiveQuizWeb.ApiSpec do
  @moduledoc """
  Builds the OpenAPI 3 specification of the JSON API.

  The document is derived at runtime from the router and from the `operation/2`
  annotations of the controllers, never from a handwritten YAML file: a route or
  a payload that changes without its annotation being updated shows up in the
  contract test instead of drifting silently.

  Every endpoint is authenticated by the `bearerAuth` scheme declared here,
  except login and refresh, which override it with an empty requirement.

  Rooms brought a second credential with them, and the two are declared side by
  side rather than folded into one: an account holds a JWT, while somebody who
  never signed up holds the opaque credential of a participation (AD-24). A
  client that is both sends both, and an operation says which of the two it
  accepts — some accept either, and the public read of a room accepts neither.
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
          },
          "participantAuth" => %SecurityScheme{
            type: "http",
            scheme: "Participant",
            description: """
            Credencial de participação, devolvida uma única vez por
            POST /api/v1/game-sessions/{code}/join. Vale enquanto a sala estiver ativa
            e identifica também participantes sem conta.
            """
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
      %Tag{name: "Perguntas", description: "Perguntas de um quiz e suas alternativas"},
      %Tag{
        name: "Salas",
        description: """
        Criação de salas, entrada de participantes com ou sem conta e ciclo de vida da partida.

        **Tempo real:** esta API não entrega eventos. A interface web usa LiveView e PubSub;
        clientes REST devem consultar o estado dos endpoints de leitura. Phoenix Channels
        estão previstos para uma fase futura, junto com o cliente mobile.
        """
      },
      %Tag{name: "Partida", description: match_tag_description()},
      %Tag{name: "Resultados", description: "Ranking, resultados imutáveis e históricos."}
    ]
  end

  # The order of the calls of a match is not deducible from an alphabetical list
  # of endpoints, so it is written down once, here, where a client reads it
  # before opening any single operation.
  defp match_tag_description do
    """
    Execução de uma partida, do início ao fim. Fluxo típico:

    ```text
    POST /api/v1/game-sessions                                      cria a sala (duração da pergunta)
    POST /api/v1/game-sessions/{code}/start                         congela o snapshot e inicia
    POST /api/v1/game-sessions/{code}/next                          avança e abre a pergunta
    POST /api/v1/game-sessions/{code}/answers                       participante responde (pode trocar)
    POST /api/v1/game-sessions/{code}/close-question                encerra por comando do host
    GET  /api/v1/game-sessions/{code}/state                         estado atual, para host ou participante
    GET  /api/v1/game-sessions/{code}/questions/{position}/results  após o encerramento
    POST /api/v1/game-sessions/{code}/finish                        finaliza a partida
    ```

    A sala é endereçada pelo **código de acesso** de 6 caracteres, o mesmo que o participante
    digita para entrar, e não por um identificador sequencial.

    **O tempo é sempre do servidor: use `ends_at`.** O campo `seconds_left` é conveniência e
    envelhece no transporte.

    **Duas credenciais, e não é a mesma.** Os comandos do host — `start`, `next`,
    `close-question` e `finish` — exigem `Authorization: Bearer <jwt>` e ser o host desta sala.
    Responder exige `Authorization: Participant <token>`, a credencial devolvida uma única vez
    pelo `join`: o host não joga, e o `Bearer` dele não identifica participação nenhuma em
    `/answers`. As leituras — `state` e `results` — aceitam qualquer uma das duas e devolvem a
    visão de quem pergunta.

    **O gabarito não vem antes da hora.** Com a pergunta aberta, nenhuma alternativa devolvida a
    quem joga traz `is_correct`; a apuração de uma pergunta que ainda não encerrou responde
    `409` `question_open`.

    ## Erros

    O `409` aparece em situações diferentes, e o cliente precisa distingui-las. Por isso as
    recusas da execução trazem, além da mensagem em pt-BR, um `code` estável em inglês em
    `errors.code` — é nele que se decide entre corrigir o payload e reconsultar o estado, nunca
    na mensagem, que é escrita para uma pessoa e pode mudar.

    | Status | `errors.code` | Quando |
    |---|---|---|
    | 409 | `invalid_status` | comando incompatível com o status da partida |
    | 409 | `no_open_question` | encerramento pedido sem pergunta aberta |
    | 409 | `no_more_questions` | avanço além da última pergunta |
    | 409 | `stale` | `expected_position` desatualizada: reconsulte `/state` |
    | 409 | `question_closed` | resposta em pergunta já encerrada |
    | 409 | `time_is_up` | resposta depois do prazo |
    | 409 | `question_open` | apuração pedida antes do encerramento |
    | 422 | `option_not_found` | alternativa que não pertence à pergunta aberta |
    | 422 | `invalid_expected_position` | corpo de `/next` sem `expected_position` |
    | 422 | `invalid_answer_option_id` | corpo de `/answers` sem `answer_option_id` |
    | 403 | `left_session` | credencial de quem saiu desta sala |

    As demais recusas se distinguem pelo **status**, e o envelope traz só a mensagem:

    | Status | Recusa | Quando |
    |---|---|---|
    | 401 | `unauthenticated` | credencial ausente ou do tipo errado para a operação |
    | 403 | `forbidden` | credencial válida de quem não pode fazer aquilo |
    | 404 | `not_found` | sala, partida ou posição inexistente |
    | 409 | `no_connected_participants` | início sem ninguém conectado |
    | 422 | `validation_error` | payload inválido, com as mensagens agrupadas por campo |
    """
  end
end
