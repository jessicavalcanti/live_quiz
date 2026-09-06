defmodule LiveQuizWeb.Api.V1.Schemas.GameStateResponse do
  @moduledoc """
  Documents the state of a match as one read rebuilds a whole screen.

  Two shapes share this schema because they share a meaning: the host, who runs
  the match, gets `answers_count` — how many people have answered so far — and
  whoever is playing gets `my_answer_option_id` with their own choice. Neither
  is required, and no reader ever receives both.

  `is_correct` is absent from an alternative while the key is withheld (AD-46)
  and present once the question closes. `seconds_left` is a courtesy that ages
  in transport: a countdown on screen is drawn from `ends_at`, the absolute
  deadline the server holds (AD-39).
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  @option %Schema{
    type: :object,
    description: "Alternativa da pergunta corrente",
    properties: %{
      id: %Schema{type: :integer, description: "Identificador da alternativa congelada"},
      position: %Schema{type: :integer, description: "Ordem da alternativa na pergunta"},
      text: %Schema{type: :string, description: "Texto da alternativa"},
      is_correct: %Schema{
        type: :boolean,
        description:
          "Gabarito congelado. Ausente enquanto a pergunta está aberta para quem joga (AD-46)"
      }
    },
    required: [:id, :position, :text]
  }

  OpenApiSpex.schema(
    %{
      title: "GameStateResponse",
      description: "Estado da partida como quem consulta tem direito de ver.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Estado corrente da partida",
          properties: %{
            status: %Schema{
              type: :string,
              description: "Situação da partida",
              example: "in_progress"
            },
            question_number: %Schema{
              type: :integer,
              nullable: true,
              description: "Posição da pergunta corrente, nula antes do primeiro avanço"
            },
            question_count: %Schema{
              type: :integer,
              description: "Quantas perguntas a partida tem"
            },
            question_state: %Schema{
              type: :string,
              enum: ["pending", "open", "closed"],
              description: "Se a pergunta corrente aceita resposta, já encerrou ou nem começou"
            },
            question_text: %Schema{
              type: :string,
              nullable: true,
              description: "Enunciado congelado da pergunta corrente"
            },
            ends_at: %Schema{
              type: :string,
              format: :"date-time",
              nullable: true,
              description: "Prazo absoluto da pergunta, em ISO 8601 UTC. A fonte do cronômetro"
            },
            seconds_left: %Schema{
              type: :integer,
              nullable: true,
              description: "Segundos restantes no instante da leitura. Conveniência, não fonte"
            },
            last_question: %Schema{
              type: :boolean,
              description: "Se a pergunta corrente é a última da partida"
            },
            options: %Schema{
              type: :array,
              description: "Alternativas da pergunta corrente, na ordem congelada",
              items: @option
            },
            answers_count: %Schema{
              type: :integer,
              description: "Quantas respostas a pergunta corrente já recebeu. Só na visão do host"
            },
            my_answer_option_id: %Schema{
              type: :integer,
              nullable: true,
              description: "Alternativa escolhida por quem consulta. Só na visão de quem joga"
            }
          },
          required: [
            :status,
            :question_number,
            :question_count,
            :question_state,
            :question_text,
            :ends_at,
            :seconds_left,
            :last_question,
            :options
          ]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "status" => "in_progress",
          "question_number" => 2,
          "question_count" => 10,
          "question_state" => "open",
          "question_text" => "Qual é a capital do Brasil?",
          "ends_at" => "2026-09-05T18:04:30Z",
          "seconds_left" => 22,
          "last_question" => false,
          "options" => [
            %{"id" => 41, "position" => 1, "text" => "São Paulo"},
            %{"id" => 42, "position" => 2, "text" => "Brasília"},
            %{"id" => 43, "position" => 3, "text" => "Rio de Janeiro"},
            %{"id" => 44, "position" => 4, "text" => "Salvador"}
          ],
          "my_answer_option_id" => 42
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
