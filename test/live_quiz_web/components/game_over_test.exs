defmodule LiveQuizWeb.GameOverTest do
  use LiveQuizWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LiveQuiz.Games.GameSession
  alias LiveQuizWeb.GameOver

  @summary %{
    status: :finished,
    question_count: 10,
    questions_played: 10,
    answers_count: 180,
    participants_count: 25
  }

  defp render_ending(viewer, reason, opts \\ []) do
    render_component(&GameOver.game_over/1,
      session: %GameSession{quiz_title: "Geografia", status: reason},
      summary: Keyword.get(opts, :summary),
      reason: reason,
      viewer: viewer
    )
  end

  defp text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  describe "partida finalizada" do
    test "anuncia o fim da partida para as duas telas" do
      assert text(render_ending(:host, :finished)) =~ "Partida finalizada"
      assert text(render_ending(:player, :finished)) =~ "Partida finalizada"
    end

    test "informa quantas perguntas foram aplicadas" do
      html = render_ending(:player, :finished, summary: @summary)

      assert text(html) =~ "Perguntas aplicadas: 10 de 10"
    end

    test "informa a partida encerrada no meio pelo que ela chegou a aplicar" do
      html = render_ending(:host, :finished, summary: %{@summary | questions_played: 4})

      assert text(html) =~ "Perguntas aplicadas: 4 de 10"
    end

    test "não fala de pontuação, posição, ranking nem acertos" do
      html = render_ending(:player, :finished, summary: @summary)

      for palavra <- ["ponto", "Ponto", "posição", "Posição", "ranking", "Ranking", "acerto"] do
        refute html =~ palavra
      end
    end

    test "omite a linha de perguntas quando não há resumo a mostrar" do
      refute render_ending(:player, :finished) =~ "questions-played"
    end

    test "omite a linha quando a sala acabou sem aplicar nenhuma pergunta" do
      html = render_ending(:host, :cancelled, summary: %{@summary | questions_played: 0})

      refute html =~ "questions-played"
    end
  end

  describe "cancelamento e expiração" do
    test "reaproveitam a tela com a mensagem da fase 2 para o host" do
      cancelled = text(render_ending(:host, :cancelled))
      expired = text(render_ending(:host, :expired))

      assert cancelled =~ "Sala cancelada"
      assert cancelled =~ "Você cancelou esta sala"
      assert expired =~ "Sala encerrada por ausência"
      assert expired =~ "ficou sem host"
    end

    test "reaproveitam a tela com a mensagem da fase 2 para quem jogou" do
      cancelled = text(render_ending(:player, :cancelled))
      expired = text(render_ending(:player, :expired))

      assert cancelled =~ "Sala cancelada pelo host"
      assert cancelled =~ "Nada deu errado do seu lado"
      assert expired =~ "Sala encerrada por ausência do host"
      assert expired =~ "ficou fora tempo demais"
    end

    test "contam as perguntas que a partida chegou a aplicar antes de acabar" do
      html = render_ending(:player, :cancelled, summary: %{@summary | questions_played: 4})

      assert text(html) =~ "Perguntas aplicadas: 4 de 10"
    end
  end

  describe "caminho de saída" do
    test "o host volta para os próprios quizzes" do
      html = render_ending(:host, :finished, summary: @summary)

      assert html =~ ~s(id="back-to-quizzes")
      assert html =~ ~s(href="/quizzes")
      refute html =~ ~s(id="back-to-join")
    end

    test "quem jogou sai para entrar em outra sala" do
      html = render_ending(:player, :finished, summary: @summary)

      assert html =~ ~s(id="back-to-join")
      assert html =~ ~s(href="/join")
      refute html =~ ~s(id="back-to-quizzes")
    end
  end

  describe "acessibilidade" do
    test "a tela é anunciada como status e nomeia o quiz" do
      html = render_ending(:player, :finished)

      assert html =~ ~s(role="status")
      assert text(html) =~ "Geografia"
    end

    test "o encerramento é o título da página de quem jogou e um subtítulo na do host" do
      assert render_ending(:player, :finished) =~ "<h1"
      assert render_ending(:host, :finished) =~ "<h2"
    end
  end
end
