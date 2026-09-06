defmodule LiveQuizWeb.Api.V1.Schemas.QuestionResultsResponse do
  @moduledoc """
  Documents the tally of a question that has closed.

  The same reading for the host and for whoever played; only
  `my_answer_option_id` and `my_answer_correct` differ, and both are null for
  the host and for whoever did not answer. An alternative nobody picked is
  listed with `count: 0` instead of disappearing from the screen (AD-43).

  There is no score, no speed bonus and no position here: phase 4 computes those
  on top of exactly these numbers.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  @option %Schema{
    type: :object,
    description: "Alternativa apurada",
    properties: %{
      id: %Schema{type: :integer, description: "Identificador da alternativa congelada"},
      position: %Schema{type: :integer, description: "Ordem da alternativa na pergunta"},
      text: %Schema{type: :string, description: "Texto da alternativa"},
      is_correct: %Schema{type: :boolean, description: "Gabarito congelado da alternativa"},
      count: %Schema{type: :integer, description: "Quantas pessoas escolheram esta alternativa"}
    },
    required: [:id, :position, :text, :is_correct, :count]
  }

  OpenApiSpex.schema(
    %{
      title: "QuestionResultsResponse",
      description: "Apuração de uma pergunta encerrada, com gabarito e distribuição.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Apuração da pergunta",
          properties: %{
            position: %Schema{type: :integer, description: "Posição da pergunta na partida"},
            question_count: %Schema{
              type: :integer,
              description: "Quantas perguntas a partida tem"
            },
            question_text: %Schema{type: :string, description: "Enunciado congelado da pergunta"},
            answers_count: %Schema{
              type: :integer,
              description: "Quantas respostas a pergunta teve"
            },
            no_answer_count: %Schema{
              type: :integer,
              description: "Quantas participações ativas deixaram de responder"
            },
            participants_count: %Schema{
              type: :integer,
              description: "Participações ativas no instante da apuração"
            },
            options: %Schema{
              type: :array,
              description: "Alternativas com o gabarito e a distribuição",
              items: @option
            },
            my_answer_option_id: %Schema{
              type: :integer,
              nullable: true,
              description: "Alternativa escolhida por quem consulta, nula para o host"
            },
            my_answer_correct: %Schema{
              type: :boolean,
              nullable: true,
              description: "Se a escolha de quem consulta era a correta, nula para o host"
            }
          },
          required: [
            :position,
            :question_count,
            :question_text,
            :answers_count,
            :no_answer_count,
            :participants_count,
            :options,
            :my_answer_option_id,
            :my_answer_correct
          ]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "position" => 2,
          "question_count" => 10,
          "question_text" => "Qual é a capital do Brasil?",
          "answers_count" => 22,
          "no_answer_count" => 3,
          "participants_count" => 25,
          "options" => [
            %{
              "id" => 41,
              "position" => 1,
              "text" => "São Paulo",
              "is_correct" => false,
              "count" => 4
            },
            %{
              "id" => 42,
              "position" => 2,
              "text" => "Brasília",
              "is_correct" => true,
              "count" => 15
            },
            %{
              "id" => 43,
              "position" => 3,
              "text" => "Rio de Janeiro",
              "is_correct" => false,
              "count" => 3
            },
            %{
              "id" => 44,
              "position" => 4,
              "text" => "Salvador",
              "is_correct" => false,
              "count" => 0
            }
          ],
          "my_answer_option_id" => 42,
          "my_answer_correct" => true
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
