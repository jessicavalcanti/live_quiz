defmodule LiveQuizWeb.GameResultLive.ListingPayloadTest do
  @moduledoc """
  What a list of results carries, and what it has no business carrying.

  Regression for R37 of the review. The listing read whole `GameResult` rows —
  `question_results` included, which is the detail of every question of every
  match on the page — to render a title, a score and a position. That JSON went
  out of the database, over the wire and into the socket, and stayed there for
  as long as the tab was open.
  """

  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Repo

  setup :register_and_log_in_user

  describe "a listagem de resultados" do
    test "não carrega o detalhe de pergunta nenhuma", %{conn: conn, user: user} do
      results = for _index <- 1..3, do: result_with_detail(user)

      {:ok, view, _html} = live(conn, ~p"/game-results")

      entries = :sys.get_state(view.pid).socket.assigns.page.entries

      assert length(entries) == 3

      for entry <- entries do
        refute Map.has_key?(entry, :question_results),
               "o resumo da listagem carregou o detalhe congelado"
      end

      # E o detalhe existe mesmo: a asserção acima não passa por vacuidade.
      for result <- results do
        assert map_size(Repo.reload!(result).question_results) > 0
      end
    end

    test "carrega exatamente os campos que a tela mostra", %{conn: conn, user: user} do
      result_with_detail(user)

      {:ok, view, _html} = live(conn, ~p"/game-results")

      [entry] = :sys.get_state(view.pid).socket.assigns.page.entries

      assert Map.keys(entry) |> Enum.sort() ==
               [:correct_answers, :final_position, :id, :inserted_at, :quiz_title, :score]
    end

    test "continua mostrando o que mostrava", %{conn: conn, user: user} do
      result_with_detail(user, quiz_title: "Geografia")

      {:ok, _view, html} = live(conn, ~p"/game-results")

      assert html =~ "Geografia"
    end

    test "o detalhe continua inteiro na tela de um resultado", %{conn: conn, user: user} do
      result = result_with_detail(user)

      {:ok, _view, html} = live(conn, ~p"/game-results/#{result.id}")

      assert html =~ "Pergunta 1 da partida"
      assert map_size(Repo.reload!(result).question_results) > 0
    end
  end

  describe "a API" do
    test "continua devolvendo o resultado inteiro", %{conn: conn, user: user} do
      result_with_detail(user)
      {:ok, token, _claims} = LiveQuiz.Accounts.Guardian.encode_and_sign(user)

      body =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> get(~p"/api/v1/users/me/game-results")
        |> json_response(200)

      assert [entry] = body["data"]
      assert map_size(entry["question_results"]) > 0
    end
  end

  # Um resultado congelado com detalhe de verdade: é ele que a listagem não
  # deve carregar.
  defp result_with_detail(user, opts \\ []) do
    host = user_fixture()
    scope = Scope.for_user(host)
    session = game_session_fixture(%{host: host, status: :in_progress})
    [snapshot] = snapshot_fixture(session, count: 1)
    participant = participant_fixture(session, %{user: user})

    {:ok, opened} = Games.advance_question(scope, session, nil)
    Games.QuestionTimer.stop(opened.id)

    clock = Repo.get!(LiveQuiz.Games.GameSessionQuestion, snapshot.id)

    answer_fixture(participant, hd(snapshot.answer_options), %{
      answered_at: DateTime.add(clock.started_at, 1, :second)
    })

    {:ok, _finished} = Games.finish_game_session(scope, opened)

    result = Repo.get_by!(LiveQuiz.Games.GameResult, participant_id: participant.id)

    case Keyword.get(opts, :quiz_title) do
      nil -> result
      title -> result |> Ecto.Changeset.change(quiz_title: title) |> Repo.update!()
    end
  end
end
