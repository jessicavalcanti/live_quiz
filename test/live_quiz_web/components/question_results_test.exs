defmodule LiveQuizWeb.QuestionResultsTest do
  use LiveQuizWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LiveQuizWeb.QuestionResults

  # A apuração é um mapa do contexto (F3-06) e o componente não lê o banco:
  # montá-lo aqui é o que deixa cada distribuição — inclusive as que ninguém
  # jogaria — descrita em uma linha.
  defp results(attrs) do
    Map.merge(
      %{
        position: 1,
        question_count: 10,
        text: "Qual é a capital do Brasil?",
        answers_count: 22,
        no_answer_count: 3,
        participants_count: 25,
        options: [
          %{id: 41, position: 1, text: "Brasília", is_correct: true, count: 15},
          %{id: 42, position: 2, text: "São Paulo", is_correct: false, count: 4},
          %{id: 43, position: 3, text: "Rio de Janeiro", is_correct: false, count: 3},
          %{id: 44, position: 4, text: "Salvador", is_correct: false, count: 0}
        ],
        my_answer_option_id: nil,
        my_answer_correct?: nil
      },
      Map.new(attrs)
    )
  end

  defp render_results(viewer, attrs \\ %{}) do
    render_component(&QuestionResults.question_results/1,
      results: results(attrs),
      viewer: viewer
    )
  end

  defp option_row(html, id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#result-option-#{id}")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp bar_widths(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#results-distribution span[style]")
    |> LazyHTML.attribute("style")
  end

  describe "gabarito" do
    test "destaca a alternativa correta na tela do host" do
      html = render_results(:host)

      assert option_row(html, 41) =~ "Resposta correta"
      assert option_row(html, 42) =~ "São Paulo"
      refute option_row(html, 42) =~ "Resposta correta"
    end

    test "destaca a mesma alternativa correta na tela de quem jogou" do
      html = render_results(:player, %{my_answer_option_id: 42, my_answer_correct?: false})

      assert option_row(html, 41) =~ "Resposta correta"
      refute option_row(html, 43) =~ "Resposta correta"
    end

    test "lista as quatro alternativas na ordem do snapshot" do
      html = render_results(:host)

      for id <- [41, 42, 43, 44] do
        assert option_row(html, id) != ""
      end
    end
  end

  describe "distribuição" do
    test "mostra a contagem e a porcentagem sobre quem respondeu" do
      html = render_results(:host)

      assert option_row(html, 41) =~ "15 respostas · 68%"
      assert option_row(html, 42) =~ "4 respostas · 18%"
      assert option_row(html, 43) =~ "3 respostas · 14%"
    end

    test "mantém na lista a alternativa que ninguém escolheu, com zero" do
      html = render_results(:host)

      assert option_row(html, 44) =~ "Salvador"
      assert option_row(html, 44) =~ "0 respostas · 0%"
    end

    test "leva a barra a 100% quando todo mundo escolheu a mesma alternativa" do
      html =
        render_results(:host, %{
          answers_count: 22,
          no_answer_count: 0,
          options: [
            %{id: 41, position: 1, text: "Brasília", is_correct: true, count: 22},
            %{id: 42, position: 2, text: "São Paulo", is_correct: false, count: 0}
          ]
        })

      assert option_row(html, 41) =~ "22 respostas · 100%"
      assert bar_widths(html) == ["width: 100%", "width: 0%"]
    end

    test "a barra não quebra quando ninguém respondeu" do
      html =
        render_results(:host, %{
          answers_count: 0,
          no_answer_count: 25,
          options: [
            %{id: 41, position: 1, text: "Brasília", is_correct: true, count: 0},
            %{id: 42, position: 2, text: "São Paulo", is_correct: false, count: 0}
          ]
        })

      assert option_row(html, 41) =~ "0 respostas · 0%"
      assert bar_widths(html) == ["width: 0%", "width: 0%"]
    end

    test "o valor da barra está em texto, e a barra em si fica fora da leitura" do
      html = render_results(:host)

      assert option_row(html, 41) =~ "15 respostas"

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s{#results-distribution span[aria-hidden="true"] span[style]})
             |> Enum.any?()
    end
  end

  describe "sem resposta" do
    test "conta quem deixou a pergunta passar" do
      assert render_results(:host) =~ "3 pessoas não responderam"
    end

    test "concorda no singular" do
      assert render_results(:host, %{no_answer_count: 1}) =~ "1 pessoa não respondeu"
    end

    test "some quando todo mundo respondeu" do
      html = render_results(:host, %{no_answer_count: 0})

      refute html =~ "não responderam"
      refute html =~ "no-answer-count"
    end
  end

  describe "resultado pessoal" do
    test "quem acertou lê que acertou" do
      html = render_results(:player, %{my_answer_option_id: 41, my_answer_correct?: true})

      assert html =~ "Você acertou!"
      assert option_row(html, 41) =~ "sua resposta"
    end

    test "quem errou lê que errou, e vê onde estava a correta" do
      html = render_results(:player, %{my_answer_option_id: 42, my_answer_correct?: false})

      assert html =~ "Você errou"
      assert option_row(html, 42) =~ "sua resposta"
      assert option_row(html, 41) =~ "Resposta correta"
      refute option_row(html, 41) =~ "sua resposta"
    end

    test "quem não respondeu lê que não respondeu" do
      html = render_results(:player)

      assert html =~ "Você não respondeu"
      refute html =~ "sua resposta"
    end

    test "o host não recebe marcação pessoal de acerto" do
      html = render_results(:host, %{my_answer_option_id: 41, my_answer_correct?: true})

      refute html =~ "own-result"
      refute html =~ "Você acertou"
      refute html =~ "Você errou"
      refute html =~ "Você não respondeu"
      refute html =~ "sua resposta"
    end
  end

  describe "escopo da fase" do
    test "não fala de pontuação, posição nem ranking" do
      html = render_results(:player, %{my_answer_option_id: 41, my_answer_correct?: true})

      for palavra <- ["ponto", "Ponto", "posição", "Posição", "ranking", "Ranking"] do
        refute html =~ palavra
      end
    end
  end
end
