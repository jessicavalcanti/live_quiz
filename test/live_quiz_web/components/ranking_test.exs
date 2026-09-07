defmodule LiveQuizWeb.RankingTest do
  use LiveQuizWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LiveQuizWeb.Ranking

  defp entry(id, position) do
    %{
      participant_id: id,
      position: position,
      nickname: "Jogador #{id}",
      score: position * 1000,
      correct_answers: position
    }
  end

  test "renderiza posições, pontuação e destaca o participante atual" do
    html =
      render_component(&Ranking.ranking/1,
        ranking: [entry(10, 1), entry(11, 2)],
        current_participant_id: 11
      )

    assert html =~ ~s(id="ranking" aria-live="polite")
    assert html =~ ~s(id="ranking-participant-10")
    assert html =~ ~s(id="ranking-participant-11")
    assert html =~ ~s(id="ranking-position-11")
    assert html =~ "2.000 pontos"
    assert html =~ "Jogador 11"
    assert html =~ ~s(id="own-ranking")
  end

  test "mantém a lista completa sem regressão com 25 participantes" do
    html =
      render_component(&Ranking.ranking/1,
        ranking: Enum.map(1..25, &entry(&1, &1)),
        current_participant_id: 25
      )

    for id <- 1..25 do
      assert html =~ ~s(id="ranking-participant-#{id}")
    end
  end
end
