defmodule LiveQuizWeb.Api.V1.GamePlayController do
  @moduledoc """
  Running and playing a match over JSON, with the same rules the web plays by.

  Not a single rule lives here. The room is read by its code, the identity comes
  from the pipeline, and `LiveQuiz.Games` decides everything else: who may
  command, who may look, whether an answer arrived in time and what a viewer is
  allowed to know. Every refusal comes back as an atom and becomes a status in
  `LiveQuizWeb.Api.FallbackController`, so a rule fixed in the context is fixed
  for both channels at once — the risk the refinement of this story called the
  worst of the phase.

  Rooms stay addressed by their join code, as the whole of the API addresses
  them since phase 2: it is what a client actually holds, and the execution had
  no reason to introduce a second way of naming the same room. The room is read
  with `LiveQuiz.Games.get_match_by_code/1`, which finds it live **or already
  over**, so a command sent to a match that ended is refused as `409` — the
  moment is wrong — instead of `404`, which would say the match never existed.

  Telling `401` from `403` is the care this controller owes its clients. No
  credential, or one of the wrong kind for what is being asked, is `401`: the
  host commands with `Authorization: Bearer` and only a participation may
  answer, so a host presenting a JWT to `/answers` is not a player with too few
  rights but somebody the endpoint cannot identify at all. A credential that is
  perfectly good and simply belongs somewhere else — another host, another
  match — is `403`.

  Reading is the one thing both identities may do, and a request carrying both
  is offered to the context as both: whichever of the two is allowed answers,
  which is what lets a host who is also taking part read the match at all. The
  context, not this module, then decides that a host sees `answers_count` and a
  player sees their own choice and no answer key while the question is open.
  """

  use LiveQuizWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.Presence
  alias LiveQuizWeb.Api.V1.Schemas.AnswerRequest
  alias LiveQuizWeb.Api.V1.Schemas.ErrorResponse
  alias LiveQuizWeb.Api.V1.Schemas.GameStateResponse
  alias LiveQuizWeb.Api.V1.Schemas.GameSummaryResponse
  alias LiveQuizWeb.Api.V1.Schemas.NextRequest
  alias LiveQuizWeb.Api.V1.Schemas.QuestionResultsResponse
  alias LiveQuizWeb.Api.V1.Schemas.SubmittedAnswerResponse
  alias LiveQuizWeb.Api.Viewer

  action_fallback LiveQuizWeb.Api.FallbackController

  tags ["Partida"]

  @code_parameter [
    in: :path,
    description: "Código de acesso da sala, com 6 caracteres",
    type: :string,
    required: true,
    example: "K7P4Q2"
  ]

  @position_parameter [
    in: :path,
    description: "Posição da pergunta na partida, a partir de 1",
    type: :integer,
    required: true,
    example: 2
  ]

  @doc """
  Advances the match to the next question and opens it for answers.
  """
  operation :next,
    summary: "Avança a partida para a próxima pergunta",
    security: [%{"bearerAuth" => []}],
    description: """
    Só o host, só com a partida em andamento. `expected_position` é obrigatório
    no corpo (AD-44): é a posição que o cliente julga corrente — `null` antes da
    primeira pergunta — e é o que impede dois avanços de pularem uma pergunta
    entre si. Divergiu, a resposta é `409` com o código `stale`.

    Uma pergunta ainda aberta é encerrada na mesma transação, e o prazo da nova
    é calculado pelo servidor a partir da duração escolhida na abertura da sala.

    **Recusas.** A coluna `errors.code` traz o código estável do corpo quando ele
    existe; onde está vazia, o status é a única distinção.

    | Status | Motivo | `errors.code` |
    |---|---|---|
    | 401 | sem token de conta — `unauthenticated` | — |
    | 403 | autenticado, mas não é o host desta partida — `forbidden` | — |
    | 404 | sala inexistente ou código inválido — `not_found` | — |
    | 409 | a partida não está em andamento | `invalid_status` |
    | 409 | a posição informada não é mais a corrente | `stale` |
    | 409 | a partida já aplicou a última pergunta | `no_more_questions` |
    | 422 | corpo sem `expected_position` | `invalid_expected_position` |
    """,
    parameters: [code: @code_parameter],
    request_body: {"Posição corrente", "application/json", NextRequest, required: true},
    responses: [
      ok: {"Partida avançada", "application/json", GameStateResponse},
      unauthorized: {"Sem token de conta", "application/json", ErrorResponse},
      forbidden:
        {"Autenticado, mas não é o host desta partida", "application/json", ErrorResponse},
      not_found: {"Sala inexistente ou código inválido", "application/json", ErrorResponse},
      conflict:
        {"Partida fora de andamento, posição desatualizada ou sem mais perguntas",
         "application/json", ErrorResponse},
      unprocessable_entity: {"Corpo sem `expected_position`", "application/json", ErrorResponse}
    ]

  def next(conn, %{"code" => code} = params) do
    scope = conn.assigns.current_scope

    with {:ok, expected} <- expected_position(params),
         {:ok, %GameSession{} = session} <- Games.get_match_by_code(code),
         {:ok, %GameSession{} = advanced} <- Games.advance_question(scope, session, expected),
         {:ok, state} <- Games.game_state(advanced, scope) do
      render(conn, :state, state: state)
    end
  end

  @doc """
  Closes the question that is open, revealing the answer key.
  """
  operation :close_question,
    summary: "Encerra a pergunta aberta",
    security: [%{"bearerAuth" => []}],
    description: """
    Só o host. Encerrar revela o gabarito e não termina a partida: mesmo a
    última pergunta espera o `finish`. Idempotente — encerrar de novo devolve
    `200` com o instante original, sem repetir a revelação.

    **Recusas.**

    | Status | Motivo | `errors.code` |
    |---|---|---|
    | 401 | sem token de conta — `unauthenticated` | — |
    | 403 | autenticado, mas não é o host desta partida — `forbidden` | — |
    | 404 | sala inexistente ou código inválido — `not_found` | — |
    | 409 | a partida não está em andamento | `invalid_status` |
    | 409 | não há pergunta aberta para encerrar | `no_open_question` |
    """,
    parameters: [code: @code_parameter],
    responses: [
      ok: {"Pergunta encerrada", "application/json", GameStateResponse},
      unauthorized: {"Sem token de conta", "application/json", ErrorResponse},
      forbidden:
        {"Autenticado, mas não é o host desta partida", "application/json", ErrorResponse},
      not_found: {"Sala inexistente ou código inválido", "application/json", ErrorResponse},
      conflict:
        {"Partida fora de andamento ou sem pergunta aberta", "application/json", ErrorResponse}
    ]

  def close_question(conn, %{"code" => code}) do
    scope = conn.assigns.current_scope

    with {:ok, %GameSession{} = session} <- Games.get_match_by_code(code),
         {:ok, %GameSession{} = closed} <- Games.close_question(scope, session),
         {:ok, state} <- Games.game_state(closed, scope) do
      render(conn, :state, state: state)
    end
  end

  @doc """
  Ends the match by the host's own decision.
  """
  operation :finish,
    summary: "Finaliza a partida",
    security: [%{"bearerAuth" => []}],
    description: """
    Só o host, a qualquer momento de uma partida em andamento — finalizar é
    decisão dele, nunca consequência de acabarem as perguntas. Idempotente: uma
    partida já finalizada é devolvida como está. Uma sala no lobby, cancelada ou
    expirada responde `409`.

    **Recusas.**

    | Status | Motivo | `errors.code` |
    |---|---|---|
    | 401 | sem token de conta — `unauthenticated` | — |
    | 403 | autenticado, mas não é o host desta partida — `forbidden` | — |
    | 404 | sala inexistente ou código inválido — `not_found` | — |
    | 409 | não há partida em andamento para finalizar | `invalid_status` |
    """,
    parameters: [code: @code_parameter],
    responses: [
      ok: {"Partida finalizada", "application/json", GameSummaryResponse},
      unauthorized: {"Sem token de conta", "application/json", ErrorResponse},
      forbidden:
        {"Autenticado, mas não é o host desta partida", "application/json", ErrorResponse},
      not_found: {"Sala inexistente ou código inválido", "application/json", ErrorResponse},
      conflict: {"Não há partida em andamento para finalizar", "application/json", ErrorResponse}
    ]

  def finish(conn, %{"code" => code}) do
    scope = conn.assigns.current_scope

    with {:ok, %GameSession{} = session} <- Games.get_match_by_code(code),
         {:ok, %GameSession{} = finished} <- Games.finish_game_session(scope, session),
         {:ok, summary} <- Games.game_summary(finished, scope) do
      render(conn, :summary, session: finished, summary: summary)
    end
  end

  @doc """
  Records the answer of a participant to the question that is open.
  """
  operation :answer,
    summary: "Responde a pergunta aberta",
    security: [%{"participantAuth" => []}],
    description: """
    Exige a credencial de participação: o host não joga, e o `Bearer` dele não
    identifica participação nenhuma nesta operação — resposta `401`. A
    credencial de outra partida responde `403`.

    Responder de novo com a pergunta aberta troca a escolha e mantém uma única
    linha (AD-41). Quando esta resposta é a última que faltava, o corpo volta
    com `question_closed` verdadeiro.

    **Recusas.**

    | Status | Motivo | `errors.code` |
    |---|---|---|
    | 401 | sem credencial de participação, o `Bearer` do host incluído — `unauthenticated` | — |
    | 403 | credencial de outra partida — `forbidden` | — |
    | 403 | credencial de quem saiu desta sala | `left_session` |
    | 404 | sala inexistente ou código inválido — `not_found` | — |
    | 409 | a partida não está em andamento | `invalid_status` |
    | 409 | a pergunta já foi encerrada | `question_closed` |
    | 409 | o prazo da pergunta venceu | `time_is_up` |
    | 422 | a alternativa não pertence à pergunta aberta | `option_not_found` |
    | 422 | corpo sem `answer_option_id` | `invalid_answer_option_id` |
    """,
    parameters: [code: @code_parameter],
    request_body: {"Alternativa escolhida", "application/json", AnswerRequest, required: true},
    responses: [
      created: {"Resposta registrada", "application/json", SubmittedAnswerResponse},
      unauthorized: {"Sem credencial de participação", "application/json", ErrorResponse},
      forbidden:
        {"Credencial de outra partida ou de quem saiu", "application/json", ErrorResponse},
      not_found: {"Sala inexistente ou código inválido", "application/json", ErrorResponse},
      conflict:
        {"Partida fora de andamento, pergunta encerrada ou prazo vencido", "application/json",
         ErrorResponse},
      unprocessable_entity:
        {"Corpo sem `answer_option_id` ou alternativa de outra pergunta", "application/json",
         ErrorResponse}
    ]

  def answer(conn, %{"code" => code} = params) do
    with {:ok, option_id} <- answer_option_id(params),
         {:ok, %GameSession{} = session} <- Games.get_match_by_code(code),
         {:ok, %Participant{} = participant} <- playing_participant(conn, session),
         {:ok, recorded} <-
           Games.answer_question(
             participant,
             option_id,
             Presence.connected_participant_ids(session.id)
           ) do
      conn
      |> put_status(:created)
      |> render(:answer, answer: recorded.answer, closed?: recorded.closed?)
    end
  end

  @doc """
  The state of the match as the caller is allowed to see it.
  """
  operation :state,
    summary: "Consulta o estado da partida",
    security: [%{"participantAuth" => []}, %{"bearerAuth" => []}],
    description: """
    A operação que aceita as duas identidades, e a que um cliente REST consulta
    no lugar dos eventos que esta API não entrega. O host recebe `answers_count`
    e quem joga recebe `my_answer_option_id`; com a pergunta aberta, quem joga
    não recebe `is_correct` em alternativa nenhuma (AD-46).

    `seconds_left` envelhece no transporte: o cronômetro da tela se desenha a
    partir de `ends_at`, que é o prazo absoluto do servidor (AD-39).

    **Recusas.** Nenhuma traz `errors.code`: as três se distinguem pelo status.

    | Status | Motivo |
    |---|---|
    | 401 | sem credencial de participação nem token de conta — `unauthenticated` |
    | 403 | identificado, mas sem vínculo com esta partida — `forbidden` |
    | 404 | sala inexistente ou código inválido — `not_found` |
    """,
    parameters: [code: @code_parameter],
    responses: [
      ok: {"Estado da partida", "application/json", GameStateResponse},
      unauthorized: {"Sem credencial nem token de conta", "application/json", ErrorResponse},
      forbidden:
        {"Identificado, mas sem vínculo com esta partida", "application/json", ErrorResponse},
      not_found: {"Sala inexistente ou código inválido", "application/json", ErrorResponse}
    ]

  def state(conn, %{"code" => code}) do
    with {:ok, %GameSession{} = session} <- Games.get_match_by_code(code),
         {:ok, state} <- Viewer.read(conn, &Games.game_state(session, &1)) do
      render(conn, :state, state: state)
    end
  end

  @doc """
  The tally of a question the match is done with.
  """
  operation :results,
    summary: "Consulta a apuração de uma pergunta",
    security: [%{"participantAuth" => []}, %{"bearerAuth" => []}],
    description: """
    A mesma leitura para o host e para quem jogou, salvo o próprio resultado.
    Uma pergunta que ainda não encerrou — ou que a partida nem alcançou —
    responde `409` com o código `question_open`: nem tela nem endpoint revelam
    gabarito antes da hora (AD-46). Uma posição que nunca foi congelada é `404`.

    **Recusas.**

    | Status | Motivo | `errors.code` |
    |---|---|---|
    | 401 | sem credencial de participação nem token de conta — `unauthenticated` | — |
    | 403 | identificado, mas sem vínculo com esta partida — `forbidden` | — |
    | 404 | sala ou posição inexistente — `not_found` | — |
    | 409 | a pergunta ainda não foi encerrada | `question_open` |
    """,
    parameters: [code: @code_parameter, position: @position_parameter],
    responses: [
      ok: {"Apuração da pergunta", "application/json", QuestionResultsResponse},
      unauthorized: {"Sem credencial nem token de conta", "application/json", ErrorResponse},
      forbidden:
        {"Identificado, mas sem vínculo com esta partida", "application/json", ErrorResponse},
      not_found: {"Sala ou posição inexistente", "application/json", ErrorResponse},
      conflict: {"A pergunta ainda não foi encerrada", "application/json", ErrorResponse}
    ]

  def results(conn, %{"code" => code, "position" => position}) do
    with {:ok, position} <- question_position(position),
         {:ok, %GameSession{} = session} <- Games.get_match_by_code(code),
         {:ok, results} <- Viewer.read(conn, &Games.question_results(session, position, &1)) do
      render(conn, :results, results: results)
    end
  end

  # Only a participation answers, and only its own match. A request with no
  # participation at all — the host's JWT included — is not identified for this
  # endpoint and stops at 401; one of another match is identified and refused.
  defp playing_participant(conn, %GameSession{id: session_id}) do
    case conn.assigns[:current_participant] do
      %Participant{game_session_id: ^session_id} = participant -> {:ok, participant}
      %Participant{} -> {:error, :unauthorized}
      nil -> {:error, :unauthenticated}
    end
  end

  # The key has to be there, and `null` is a value it may legitimately carry:
  # that is what "there is no question yet" looks like. A body that omits it is
  # a client without the protection of AD-44, which is why it is refused instead
  # of read as `nil`.
  defp expected_position(params) do
    case Map.fetch(params, "expected_position") do
      {:ok, nil} -> {:ok, nil}
      {:ok, position} when is_integer(position) and position > 0 -> {:ok, position}
      _absent_or_invalid -> {:error, :invalid_expected_position}
    end
  end

  defp answer_option_id(params) do
    case Map.fetch(params, "answer_option_id") do
      {:ok, id} when is_integer(id) -> {:ok, id}
      _absent_or_invalid -> {:error, :invalid_answer_option_id}
    end
  end

  # A position that is not a number names no question, which is the same news as
  # a position the match never froze: there is nothing there to tally.
  defp question_position(position) when is_binary(position) do
    case Integer.parse(position) do
      {number, ""} when number > 0 -> {:ok, number}
      _not_a_position -> {:error, :not_found}
    end
  end
end
