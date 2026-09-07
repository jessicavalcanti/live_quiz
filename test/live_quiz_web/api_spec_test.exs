defmodule LiveQuizWeb.ApiSpecTest do
  @moduledoc """
  Contract test of the OpenAPI specification.

  The specification is derived from the router and from the `operation/2`
  annotations of the controllers, so a route added without its annotation — or
  an annotation that stops matching what the API answers — fails here instead of
  drifting silently.
  """

  use LiveQuizWeb.ConnCase, async: true

  alias LiveQuizWeb.ApiSpec

  @authenticated_operations [
    {"/api/v1/session", "delete"},
    {"/api/v1/me", "get"},
    {"/api/v1/quizzes", "get"},
    {"/api/v1/quizzes", "post"},
    {"/api/v1/quizzes/{id}", "get"},
    {"/api/v1/quizzes/{id}", "put"},
    {"/api/v1/quizzes/{id}", "patch"},
    {"/api/v1/quizzes/{id}", "delete"},
    {"/api/v1/quizzes/{quiz_id}/questions", "get"},
    {"/api/v1/quizzes/{quiz_id}/questions", "post"},
    {"/api/v1/quizzes/{quiz_id}/questions/{id}", "get"},
    {"/api/v1/quizzes/{quiz_id}/questions/{id}", "put"},
    {"/api/v1/quizzes/{quiz_id}/questions/{id}", "patch"},
    {"/api/v1/quizzes/{quiz_id}/questions/{id}", "delete"},
    {"/api/v1/quizzes/{quiz_id}/questions/{id}/move", "patch"},
    {"/api/v1/game-sessions/{code}/results", "get"},
    {"/api/v1/game-sessions/{code}/results/me", "get"},
    {"/api/v1/users/me/game-results", "get"},
    {"/api/v1/quizzes/{quiz_id}/game-history", "get"}
  ]

  @host_operations [
    {"/api/v1/game-sessions", "post"},
    {"/api/v1/game-sessions/{code}/host", "get"},
    {"/api/v1/game-sessions/{code}/start", "post"},
    {"/api/v1/game-sessions/{code}/cancel", "post"},
    {"/api/v1/game-sessions/{code}/next", "post"},
    {"/api/v1/game-sessions/{code}/close-question", "post"},
    {"/api/v1/game-sessions/{code}/finish", "post"}
  ]

  # The seven operations of the execution, in the order a match calls them. They
  # are the ones the tag `Partida` gathers; everything else about a room stays
  # under `Salas`.
  @match_operations [
    {"/api/v1/game-sessions/{code}/start", "post"},
    {"/api/v1/game-sessions/{code}/next", "post"},
    {"/api/v1/game-sessions/{code}/answers", "post"},
    {"/api/v1/game-sessions/{code}/close-question", "post"},
    {"/api/v1/game-sessions/{code}/state", "get"},
    {"/api/v1/game-sessions/{code}/questions/{position}/results", "get"},
    {"/api/v1/game-sessions/{code}/finish", "post"}
  ]

  # The reasons of the error table of F3-12. The first group travels in
  # `errors.code`; the second is told apart by the status alone, and the
  # documentation has to say which is which instead of implying a code that no
  # response carries.
  @coded_refusals [
    "invalid_status",
    "no_open_question",
    "no_more_questions",
    "stale",
    "question_closed",
    "time_is_up",
    "question_open",
    "option_not_found",
    "invalid_expected_position",
    "invalid_answer_option_id",
    "left_session"
  ]

  @status_only_refusals [
    "unauthenticated",
    "forbidden",
    "not_found",
    "no_connected_participants",
    "validation_error"
  ]

  @participant_operations [
    {"/api/v1/game-sessions/{code}/me", "get"},
    {"/api/v1/game-sessions/{code}/rejoin", "post"},
    {"/api/v1/game-sessions/{code}/leave", "delete"},
    {"/api/v1/game-sessions/{code}/answers", "post"}
  ]

  # The lobby list and the reads of a running match are what either identity may
  # open, and entering a room is the one that takes any of the three — including
  # none at all.
  @either_operations [
    {"/api/v1/game-sessions/{code}/participants", "get"},
    {"/api/v1/game-sessions/{code}/state", "get"},
    {"/api/v1/game-sessions/{code}/questions/{position}/results", "get"},
    {"/api/v1/game-sessions/{code}/ranking", "get"}
  ]

  @open_operations [{"/api/v1/game-sessions/{code}/join", "post"}]

  @room_operations @host_operations ++
                     @participant_operations ++
                     @either_operations ++
                     @open_operations ++ [{"/api/v1/game-sessions/{code}", "get"}]

  @public_operations [
    {"/api/v1/session", "post"},
    {"/api/v1/session/refresh", "post"},
    {"/api/v1/game-sessions/{code}", "get"}
  ]

  # The statuses of the error map of F2-11 and F3-11, per operation, on top of
  # the success.
  @room_error_statuses %{
    {"/api/v1/game-sessions", "post"} => ["401", "404", "409", "422", "503"],
    {"/api/v1/game-sessions/{code}", "get"} => ["404"],
    {"/api/v1/game-sessions/{code}/host", "get"} => ["401", "404"],
    {"/api/v1/game-sessions/{code}/join", "post"} => ["404", "409", "422"],
    {"/api/v1/game-sessions/{code}/start", "post"} => ["401", "404", "409"],
    {"/api/v1/game-sessions/{code}/cancel", "post"} => ["401", "404", "409"],
    {"/api/v1/game-sessions/{code}/participants", "get"} => ["401", "403", "404"],
    {"/api/v1/game-sessions/{code}/me", "get"} => ["401", "404"],
    {"/api/v1/game-sessions/{code}/rejoin", "post"} => ["401", "404", "409", "410"],
    {"/api/v1/game-sessions/{code}/leave", "delete"} => ["401", "404"],
    {"/api/v1/game-sessions/{code}/next", "post"} => ["401", "403", "404", "409", "422"],
    {"/api/v1/game-sessions/{code}/close-question", "post"} => [
      "401",
      "403",
      "404",
      "409",
      "422"
    ],
    {"/api/v1/game-sessions/{code}/finish", "post"} => ["401", "403", "404", "409"],
    {"/api/v1/game-sessions/{code}/answers", "post"} => ["401", "403", "404", "409", "422"],
    {"/api/v1/game-sessions/{code}/state", "get"} => ["401", "403", "404"],
    {"/api/v1/game-sessions/{code}/questions/{position}/results", "get"} => [
      "401",
      "403",
      "404",
      "409"
    ],
    {"/api/v1/game-sessions/{code}/ranking", "get"} => ["401", "403", "404"],
    {"/api/v1/game-sessions/{code}/results", "get"} => ["401", "404"],
    {"/api/v1/game-sessions/{code}/results/me", "get"} => ["401", "404"],
    {"/api/v1/users/me/game-results", "get"} => ["401", "422"],
    {"/api/v1/quizzes/{quiz_id}/game-history", "get"} => ["401", "404", "422"]
  }

  describe "GET /api/openapi" do
    test "answers 200 with an OpenAPI 3 document", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      assert String.starts_with?(spec["openapi"], "3.")
      assert spec["info"]["title"] == "Live Quiz API"
      assert spec["info"]["version"] == "1.0.0"
      assert is_map(spec["paths"])
    end

    test "does not require authentication", %{conn: conn} do
      assert build_conn() |> get(~p"/api/openapi") |> json_response(200)
      assert conn |> get(~p"/api/openapi") |> json_response(200)
    end

    test "documents every implemented path", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      documented = @authenticated_operations ++ @public_operations ++ @room_operations

      for {path, verb} <- documented do
        assert %{"summary" => summary} = spec["paths"][path][verb]
        assert is_binary(summary)
      end

      assert Map.keys(spec["paths"]) |> Enum.sort() ==
               documented |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    end
  end

  describe "specification" do
    test "is generated by to_map/1 without raising" do
      map = ApiSpec.spec() |> OpenApiSpex.OpenApi.to_map()

      assert is_map(map["paths"])
      assert is_map(map["components"]["schemas"])
      assert Jason.encode!(map) =~ "Live Quiz API"
    end

    test "declares the bearerAuth security scheme", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      assert spec["components"]["securitySchemes"]["bearerAuth"]["type"] == "http"
      assert spec["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"
      assert spec["components"]["securitySchemes"]["bearerAuth"]["bearerFormat"] == "JWT"
      assert spec["security"] == [%{"bearerAuth" => []}]
    end

    test "requires bearerAuth on every authenticated operation", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      for {path, verb} <- @authenticated_operations ++ @host_operations do
        assert spec["paths"][path][verb]["security"] == [%{"bearerAuth" => []}],
               "#{String.upcase(verb)} #{path} deveria exigir bearerAuth"
      end
    end

    test "exempts the public operations from every security scheme", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      for {path, verb} <- @public_operations do
        assert spec["paths"][path][verb]["security"] == [],
               "#{String.upcase(verb)} #{path} não deveria exigir bearerAuth"
      end
    end

    test "groups the operations by tag", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      assert Enum.map(spec["tags"], & &1["name"]) ==
               ["Sessão", "Quizzes", "Perguntas", "Salas", "Partida", "Resultados"]

      assert spec["paths"]["/api/v1/me"]["get"]["tags"] == ["Sessão"]
      assert spec["paths"]["/api/v1/quizzes"]["get"]["tags"] == ["Quizzes"]
      assert spec["paths"]["/api/v1/quizzes/{quiz_id}/questions"]["get"]["tags"] == ["Perguntas"]

      for {path, verb} <-
            (@room_operations -- @match_operations) --
              [
                {"/api/v1/game-sessions/{code}/ranking", "get"},
                {"/api/v1/game-sessions/{code}/results", "get"},
                {"/api/v1/game-sessions/{code}/results/me", "get"},
                {"/api/v1/users/me/game-results", "get"},
                {"/api/v1/quizzes/{quiz_id}/game-history", "get"}
              ] do
        assert spec["paths"][path][verb]["tags"] == ["Salas"],
               "#{String.upcase(verb)} #{path} deveria estar na tag Salas"
      end
    end

    test "documents 201, 401, 404, 409 and 422 on the creation of a question", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      responses = spec["paths"]["/api/v1/quizzes/{quiz_id}/questions"]["post"]["responses"]

      assert Enum.sort(Map.keys(responses)) == ["201", "401", "404", "409", "422"]

      for {_status, response} <- responses do
        assert is_binary(response["description"])
      end
    end

    test "documents the pagination of the quiz listing", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      operation = spec["paths"]["/api/v1/quizzes"]["get"]

      assert Enum.map(operation["parameters"], & &1["name"]) == ["page", "per_page", "search"]

      for parameter <- operation["parameters"] do
        assert parameter["in"] == "query"
        assert is_binary(parameter["description"])
      end

      assert operation["responses"]["200"]["content"]["application/json"]["schema"] == %{
               "$ref" => "#/components/schemas/QuizListResponse"
             }

      assert %{"$ref" => "#/components/schemas/PaginationMeta"} =
               spec["components"]["schemas"]["QuizListResponse"]["properties"]["meta"]
    end

    test "gives every schema a description and an example", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      schemas = spec["components"]["schemas"]

      assert map_size(schemas) == 43

      for {name, schema} <- schemas do
        assert is_binary(schema["description"]), "schema #{name} está sem description"
        assert schema["example"], "schema #{name} está sem example"
      end
    end

    test "describes the result payloads without anonymous objects", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      assert spec["components"]["schemas"]["RankingResponse"]["properties"]["data"]["items"] ==
               %{"$ref" => "#/components/schemas/RankingEntry"}

      assert spec["components"]["schemas"]["GameResultResponse"]["properties"]["data"] ==
               %{"$ref" => "#/components/schemas/GameResult"}

      assert spec["components"]["schemas"]["GameResultListResponse"]["properties"]["data"][
               "items"
             ] ==
               %{"$ref" => "#/components/schemas/GameResult"}

      assert spec["paths"]["/api/v1/quizzes/{quiz_id}/game-history"]["get"]["responses"]["200"][
               "content"
             ]["application/json"]["schema"] == %{
               "$ref" => "#/components/schemas/GameHistoryResponse"
             }
    end
  end

  describe "specification of the rooms" do
    test "survives the round trip through JSON and back into an OpenApi struct" do
      spec = ApiSpec.spec()

      decoded =
        spec
        |> OpenApiSpex.OpenApi.to_map()
        |> Jason.encode!()
        |> Jason.decode!()
        |> OpenApiSpex.OpenApi.Decode.decode()

      assert %OpenApiSpex.OpenApi{} = decoded
      assert String.starts_with?(decoded.openapi, "3.")
      assert map_size(decoded.paths) == map_size(spec.paths)
      assert map_size(decoded.components.schemas) == map_size(spec.components.schemas)
      assert Map.keys(decoded.components.securitySchemes) == ["bearerAuth", "participantAuth"]
    end

    test "documents the sixteen operations of the rooms", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      assert length(@room_operations) == 17

      for {path, verb} <- @room_operations do
        operation = spec["paths"][path][verb]

        assert is_binary(operation["summary"]), "#{String.upcase(verb)} #{path} está sem summary"
        assert is_binary(operation["description"]), "#{String.upcase(verb)} #{path} sem descrição"
        assert is_binary(operation["operationId"])
      end
    end

    test "gives every operation of the whole specification a unique operationId", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      ids =
        for {_path, item} <- spec["paths"],
            {_verb, operation} <- item,
            is_map(operation),
            do: operation["operationId"]

      assert ids != []
      assert Enum.uniq(ids) == ids

      room_ids =
        for {path, verb} <- @room_operations, do: spec["paths"][path][verb]["operationId"]

      assert length(Enum.uniq(room_ids)) == 17
      assert room_ids -- ids == []
    end

    test "declares participantAuth alongside bearerAuth", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      scheme = spec["components"]["securitySchemes"]["participantAuth"]

      assert scheme["type"] == "http"
      assert scheme["scheme"] == "Participant"
      assert scheme["description"] =~ "uma única vez"
      assert spec["components"]["securitySchemes"]["bearerAuth"]
    end

    test "requires the participation credential where only it identifies", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      for {path, verb} <- @participant_operations do
        assert spec["paths"][path][verb]["security"] == [%{"participantAuth" => []}],
               "#{String.upcase(verb)} #{path} deveria exigir participantAuth"
      end
    end

    test "accepts either identity on the lobby listing", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      for {path, verb} <- @either_operations do
        assert spec["paths"][path][verb]["security"] ==
                 [%{"participantAuth" => []}, %{"bearerAuth" => []}]
      end
    end

    test "lets entering a room be called with no identity at all", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      for {path, verb} <- @open_operations do
        assert spec["paths"][path][verb]["security"] ==
                 [%{}, %{"bearerAuth" => []}, %{"participantAuth" => []}]
      end
    end

    test "documents exactly the statuses the endpoints answer with", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      for {{path, verb}, errors} <- @room_error_statuses do
        responses = spec["paths"][path][verb]["responses"]
        documented = responses |> Map.keys() |> Enum.sort()

        assert errors -- documented == [],
               "#{String.upcase(verb)} #{path} não documenta #{inspect(errors -- documented)}"

        assert Enum.all?(documented -- errors, &String.starts_with?(&1, "2")),
               "#{String.upcase(verb)} #{path} documenta erro que não devolve"

        for {status, response} <- responses do
          assert is_binary(response["description"]), "#{path} #{verb} #{status} sem descrição"
        end
      end
    end

    test "keeps every participant field out of the public read of a room", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      public = spec["components"]["schemas"]["GameSessionPublic"]

      assert Enum.sort(Map.keys(public["properties"])) ==
               ["available", "code", "quiz_title", "status"]

      refute Jason.encode!(public) =~ "articipant"

      assert spec["paths"]["/api/v1/game-sessions/{code}"]["get"]["responses"]["200"]["content"][
               "application/json"
             ]["schema"] == %{"$ref" => "#/components/schemas/GameSessionPublicResponse"}
    end

    test "documents the credential in the answer of join and nowhere else", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      join = spec["components"]["schemas"]["JoinResponse"]
      token = join["properties"]["data"]["properties"]["participant_token"]

      assert token["type"] == "string"
      assert token["description"] =~ "uma única vez"
      assert "participant_token" in join["properties"]["data"]["required"]

      carriers =
        for {name, schema} <- spec["components"]["schemas"],
            Jason.encode!(schema) =~ "participant_token",
            do: name

      assert carriers == ["JoinResponse"]

      assert spec["paths"]["/api/v1/game-sessions/{code}/join"]["post"]["responses"]["201"][
               "content"
             ]["application/json"]["schema"] == %{"$ref" => "#/components/schemas/JoinResponse"}
    end

    test "explains in the tag that the API delivers no real time", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      rooms = Enum.find(spec["tags"], &(&1["name"] == "Salas"))

      assert rooms["description"] =~ "não entrega eventos"
      assert rooms["description"] =~ "Channels"
    end

    test "rejects a join without a nickname by the schema itself" do
      spec = ApiSpec.spec()
      schema = spec.components.schemas["JoinRequest"]

      assert {:error, [%OpenApiSpex.Cast.Error{reason: :missing_field, name: :nickname}]} =
               OpenApiSpex.cast_value(%{}, schema, spec)

      assert {:error, [%OpenApiSpex.Cast.Error{reason: :min_length}]} =
               OpenApiSpex.cast_value(%{"nickname" => "A"}, schema, spec)

      assert {:ok, %{nickname: "Ana"}} =
               OpenApiSpex.cast_value(%{"nickname" => "Ana"}, schema, spec)
    end

    test "declares examples that are valid against their own schema" do
      spec = ApiSpec.spec()

      for {name, schema} <- spec.components.schemas, example = schema.example do
        assert {:ok, _cast} = OpenApiSpex.cast_value(example, schema, spec),
               "o exemplo do schema #{name} não é válido contra ele mesmo"
      end
    end
  end

  describe "specification of the match" do
    test "documents the seven operations of the match under the tag Partida", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      assert length(@match_operations) == 7

      for {path, verb} <- @match_operations do
        operation = spec["paths"][path][verb]

        assert is_map(operation), "#{String.upcase(verb)} #{path} não está documentado"
        assert operation["tags"] == ["Partida"], "#{String.upcase(verb)} #{path} fora da Partida"
        assert is_binary(operation["operationId"])
        assert is_binary(operation["summary"])
        assert is_binary(operation["description"])

        assert Enum.any?(Map.keys(operation["responses"]), &String.starts_with?(&1, "2")),
               "#{String.upcase(verb)} #{path} não documenta resposta de sucesso"

        for {status, response} <- operation["responses"] do
          assert is_binary(response["description"]), "#{path} #{verb} #{status} sem descrição"

          assert get_in(response, ["content", "application/json", "schema"]),
                 "#{path} #{verb} #{status} sem schema"
        end
      end
    end

    test "requires a body only where the match reads one", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      bodies =
        for {path, verb} <- @match_operations,
            body = spec["paths"][path][verb]["requestBody"],
            into: %{},
            do: {path, get_in(body, ["content", "application/json", "schema"])}

      assert bodies == %{
               "/api/v1/game-sessions/{code}/next" => %{
                 "$ref" => "#/components/schemas/NextRequest"
               },
               "/api/v1/game-sessions/{code}/answers" => %{
                 "$ref" => "#/components/schemas/AnswerRequest"
               },
               "/api/v1/game-sessions/{code}/close-question" => %{
                 "$ref" => "#/components/schemas/CloseRequest"
               }
             }

      # Encerrar aceita o corpo, mas não o exige: um cliente escrito antes de
      # ele existir continua encerrando a pergunta corrente.
      close = spec["paths"]["/api/v1/game-sessions/{code}/close-question"]["post"]

      refute close["requestBody"]["required"]
      assert spec["paths"]["/api/v1/game-sessions/{code}/next"]["post"]["requestBody"]["required"]
    end

    test "describes the order of the calls of a whole match in the tag", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      description = Enum.find(spec["tags"], &(&1["name"] == "Partida"))["description"]

      flow = ["/start", "/next", "/answers", "/close-question", "/state", "/results", "/finish"]

      positions = Enum.map(flow, &(description |> String.split(&1) |> hd() |> String.length()))

      assert positions == Enum.sort(positions),
             "a descrição da tag não traz as chamadas na ordem de uma partida"

      assert description =~ "ends_at"
      assert description =~ "seconds_left"
      assert description =~ "Authorization: Participant"
      assert description =~ "Authorization: Bearer"
    end

    test "lists every refusal of the error table in the tag", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      description = Enum.find(spec["tags"], &(&1["name"] == "Partida"))["description"]

      for refusal <- @coded_refusals ++ @status_only_refusals do
        assert description =~ "`#{refusal}`", "a tag Partida não documenta #{refusal}"
      end
    end

    test "documents every coded refusal in an operation, with its status", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      documented = documented_codes(spec)

      expected = %{
        "invalid_status" => "409",
        "no_open_question" => "409",
        "no_more_questions" => "409",
        "stale" => "409",
        "question_closed" => "409",
        "time_is_up" => "409",
        "question_open" => "409",
        "option_not_found" => "422",
        "invalid_expected_position" => "422",
        "invalid_answer_option_id" => "422",
        "left_session" => "403"
      }

      assert Enum.sort(@coded_refusals) == expected |> Map.keys() |> Enum.sort()

      for {code, status} <- expected do
        assert status in Map.get(documented, code, []),
               "#{code} não está documentado com o status #{status} em nenhuma operação"
      end
    end

    test "never presents as a code a refusal that answers without one", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      documented = documented_codes(spec)

      for refusal <- @status_only_refusals do
        refute Map.has_key?(documented, refusal),
               "#{refusal} aparece como errors.code, mas o corpo não traz código nenhum"

        assert Enum.any?(operation_descriptions(spec), &(&1 =~ "`#{refusal}`")),
               "#{refusal} não é citado em nenhuma operação"
      end
    end

    test "documents the refusals of answering with their statuses", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      description = spec["paths"]["/api/v1/game-sessions/{code}/answers"]["post"]["description"]

      codes = description |> refusal_rows() |> codes_by_status()

      assert codes["question_closed"] == "409"
      assert codes["time_is_up"] == "409"
      assert codes["option_not_found"] == "422"
      assert codes["invalid_answer_option_id"] == "422"
      assert codes["left_session"] == "403"
    end

    test "documents the duration of the questions with its options and its default", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      duration =
        spec["components"]["schemas"]["GameSessionRequest"]["properties"][
          "question_duration_seconds"
        ]

      assert duration["type"] == "integer"
      assert duration["enum"] == [10, 20, 30, 60]
      assert duration["default"] == 30
      assert is_binary(duration["description"])

      refute "question_duration_seconds" in spec["components"]["schemas"]["GameSessionRequest"][
               "required"
             ]
    end

    test "keeps the answer key out of the example of an open question", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      example = spec["components"]["schemas"]["GameStateResponse"]["example"]

      assert example["data"]["question_state"] == "open"
      assert length(example["data"]["options"]) == 4

      for option <- example["data"]["options"] do
        refute Map.has_key?(option, "is_correct"),
               "o exemplo de uma pergunta aberta traz o gabarito"
      end

      refute Jason.encode!(example) =~ "is_correct"
    end

    test "shows the answer key and the tally in the example of the results", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      example = spec["components"]["schemas"]["QuestionResultsResponse"]["example"]
      options = example["data"]["options"]

      assert length(options) == 4
      assert Enum.count(options, & &1["is_correct"]) == 1
      assert Enum.all?(options, &is_integer(&1["count"]))

      # An alternative nobody picked is listed with zero, never left out (AD-43).
      assert 0 in Enum.map(options, & &1["count"])
    end

    test "gives every schema of the match a description and an example", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      names = [
        "AnswerRequest",
        "NextRequest",
        "GameStateResponse",
        "QuestionResultsResponse",
        "SubmittedAnswerResponse",
        "GameSummaryResponse",
        "GameSessionRequest"
      ]

      for name <- names do
        schema = spec["components"]["schemas"][name]

        assert is_map(schema), "o schema #{name} não está na especificação"
        assert is_binary(schema["description"]), "o schema #{name} está sem description"
        assert is_map(schema["example"]), "o schema #{name} está sem example"
      end
    end

    test "keeps the paths of the earlier phases documented", %{conn: conn} do
      spec = conn |> get(~p"/api/openapi") |> json_response(200)

      for {path, verb} <- @authenticated_operations ++ @public_operations do
        assert is_map(spec["paths"][path][verb]), "#{String.upcase(verb)} #{path} sumiu"
      end

      for {path, verb} <-
            (@room_operations -- @match_operations) --
              [
                {"/api/v1/game-sessions/{code}/ranking", "get"},
                {"/api/v1/game-sessions/{code}/results", "get"},
                {"/api/v1/game-sessions/{code}/results/me", "get"},
                {"/api/v1/users/me/game-results", "get"},
                {"/api/v1/quizzes/{quiz_id}/game-history", "get"}
              ] do
        assert spec["paths"][path][verb]["tags"] == ["Salas"]
      end
    end
  end

  # The refusal tables of the operations are markdown, which is what Swagger UI
  # renders. Reading them back as rows is what lets the test check that a code
  # is documented with the status it actually answers with.
  defp refusal_rows(description) do
    description
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.map(fn row -> row |> String.split("|", trim: true) |> Enum.map(&String.trim/1) end)
    |> Enum.filter(fn
      [status | _rest] -> String.match?(status, ~r/^\d{3}$/)
      _other -> false
    end)
  end

  defp codes_by_status(rows) do
    for [status, _reason, code] <- rows,
        code != "—",
        into: %{},
        do: {String.trim(code, "`"), status}
  end

  defp operation_descriptions(spec) do
    for {_path, item} <- spec["paths"],
        {_verb, operation} <- item,
        is_map(operation),
        description = operation["description"],
        is_binary(description),
        do: description
  end

  defp documented_codes(spec) do
    spec
    |> operation_descriptions()
    |> Enum.flat_map(&(&1 |> refusal_rows() |> codes_by_status() |> Map.to_list()))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  describe "GET /api/docs" do
    test "answers 200 with the Swagger UI", %{conn: conn} do
      html = conn |> get(~p"/api/docs") |> html_response(200)

      assert html =~ "SwaggerUIBundle"
      assert html =~ "/api/openapi"
    end
  end
end
