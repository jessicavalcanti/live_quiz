defmodule LiveQuizWeb.ResultDetailTest do
  @moduledoc """
  O bloco de resultado, que duas telas dividem (R41).

  A regra que valia testar aqui não é o cartão: é a distinção entre errar e não
  responder, e a ordem das perguntas. Estavam escritas duas vezes, uma em cada
  tela, que é onde uma delas ia parar de concordar com a outra.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import LiveQuizWeb.ResultDetail

  @result %{
    score: 1234,
    final_position: 2,
    correct_answers: 3,
    answered_questions: 4,
    average_response_time_ms: 2500,
    question_results: %{}
  }

  test "mostra as cinco métricas da partida" do
    html = render_detail(@result)

    assert html =~ "Pontuação"
    assert html =~ "Posição"
    assert html =~ "#2"
    assert html =~ "Acertos"
    assert html =~ "Respondidas"
    assert html =~ "Tempo médio"
  end

  test "não responder não é a mesma coisa que errar" do
    html =
      render_detail(%{
        @result
        | question_results: %{
            "1" => %{"question" => "Capital", "correct" => true, "answer" => "Brasília"},
            "2" => %{"question" => "Cor", "correct" => false, "answer" => "Verde"},
            "3" => %{"question" => "Ano", "correct" => nil, "answer" => nil}
          }
      })

    assert html =~ "Correta"
    assert html =~ "Incorreta"
    assert html =~ "Sem resposta"
    assert html =~ "badge badge-success"
    assert html =~ "badge badge-error"
    assert html =~ "badge badge-ghost"

    # Quem não respondeu lê "Não respondida", e não um espaço em branco que
    # parece um erro de renderização.
    assert html =~ "Não respondida"
  end

  test "ordena as perguntas por posição, e não pela string" do
    results =
      for position <- 1..11, into: %{} do
        {to_string(position), %{"question" => "Pergunta #{position}", "correct" => true}}
      end

    html = render_detail(%{@result | question_results: results})

    # As chaves vêm do JSON como texto: ordenadas como texto, a pergunta 10
    # apareceria entre a 1 e a 2.
    assert positions(html) == Enum.to_list(1..11)
  end

  test "cada tela tem o seu prefixo, para que uma não alcance a outra" do
    html = render_detail(%{@result | question_results: %{"1" => %{"question" => "Q"}}})

    assert html =~ ~s(id="prova-questions")
    assert html =~ ~s(id="prova-question-1")
  end

  defp render_detail(result) do
    assigns = %{result: result}

    rendered_to_string(~H"""
    <.result_detail id="prova" result={@result} heading="Detalhes por pergunta">
      <:header>
        <h1>Cabeçalho da tela</h1>
      </:header>
    </.result_detail>
    """)
  end

  defp positions(html) do
    ~r/id="prova-question-(\d+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_match, position] -> String.to_integer(position) end)
  end
end
