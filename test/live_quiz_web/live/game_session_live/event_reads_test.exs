defmodule LiveQuizWeb.GameSessionLive.EventReadsTest do
  @moduledoc """
  How many queries one room event costs each screen watching the room.

  Regression for R38 of the review. Every event of a room reaches every socket
  in it, and each socket answered by re-reading both the lobby and the match —
  so a room of twenty-five people turned one person joining into fifty reads,
  half of them about a match the event said nothing about.

  These tests count. The numbers are asserted rather than described, because a
  regression here is silent: nothing breaks, the room just costs more.
  """

  use LiveQuizWeb.ConnCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games

  describe "no lobby" do
    setup :player_in_lobby

    test "a entrada de alguém custa só a leitura do lobby", %{view: view} do
      assert queries_for(view, {:participant_joined, nil}) == lobby_reads()
    end

    test "uma mudança de presença custa só a leitura do lobby", %{view: view, session: session} do
      assert queries_for(view, {:presence_changed, session.id}) == lobby_reads()
    end
  end

  describe "durante a partida" do
    setup :player_in_match

    test "o avanço da pergunta não relê o lobby", %{view: view, session: session} do
      current = LiveQuiz.Repo.get!(LiveQuiz.Games.GameSession, session.id)

      # O evento fala da partida. Reler a lista de participantes junto era
      # trabalho que nenhum campo da tela usava (R38).
      assert queries_for(view, {:question_advanced, current}) == match_reads()
    end

    test "uma resposta de outra pessoa não custa leitura nenhuma", %{
      view: view,
      session: session
    } do
      # A contagem de respostas alheias não aparece na tela de quem joga, então
      # não há o que reler.
      assert queries_for(view, {:answer_submitted, session.id, 1}) == 0
    end

    test "uma mudança de presença ainda relê o lobby", %{view: view, session: session} do
      # Aqui o lobby é necessário: quem está conectado decide se esta resposta
      # foi a última que faltava.
      assert queries_for(view, {:presence_changed, session.id}) == lobby_reads()
    end
  end

  # Quantas consultas cada leitura custa hoje. Os números vivem aqui, uma vez,
  # para os testes falarem de "uma leitura do lobby" em vez de um inteiro solto.
  # Se um deles subir, é porque alguém acrescentou uma consulta a um caminho que
  # roda uma vez por socket por evento.
  defp lobby_reads, do: 1

  # `game_state/2` é uma leitura só, mas custa cinco consultas: a sala, quantas
  # perguntas o snapshot tem, a pergunta corrente, as alternativas dela e a
  # própria resposta. Não há duplicação a remover aqui — o que havia era ler
  # isso tudo também quando o evento falava do lobby.
  defp match_reads, do: 5

  # Conta as consultas que o processo da LiveView faz ao processar um evento.
  defp queries_for(view, message) do
    parent = self()
    ref = make_ref()
    handler = {__MODULE__, ref}
    pid = view.pid

    # A montagem registra presença, e a presença anuncia. Esses avisos chegam
    # sozinhos e contariam como custo do evento que este teste está medindo.
    settle(pid)

    :telemetry.attach(
      handler,
      [:live_quiz, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == pid, do: send(parent, {ref, :query})
      end,
      nil
    )

    send(pid, message)
    _settled = :sys.get_state(pid)
    :telemetry.detach(handler)

    drain(ref, 0)
  end

  # Espera a caixa de mensagens esvaziar: `:sys.get_state` só garante que o que
  # já estava enfileirado foi processado, e um anúncio de presença pode chegar
  # logo depois.
  defp settle(pid, attempts \\ 20)
  defp settle(_pid, 0), do: :ok

  defp settle(pid, attempts) do
    _state = :sys.get_state(pid)

    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, 0} -> :ok
      _still_busy -> settle(pid, attempts - 1)
    end
  end

  defp drain(ref, count) do
    receive do
      {^ref, :query} -> drain(ref, count + 1)
    after
      50 -> count
    end
  end

  defp player_in_lobby(%{conn: conn}) do
    session = game_session_fixture(%{status: :waiting})
    {participant, token} = credentialed_participant_fixture(session)

    conn = put_participant_token(conn, session.join_code, token)
    {:ok, view, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

    %{view: view, session: session, participant: participant}
  end

  defp player_in_match(%{conn: conn}) do
    host = user_fixture()
    scope = Scope.for_user(host)
    quiz = quiz_fixture(scope)
    question_fixture(scope, quiz)

    session = game_session_fixture(%{host: host, quiz: quiz, status: :in_progress})
    snapshot_fixture(session, count: 2)
    {participant, token} = credentialed_participant_fixture(session)

    {:ok, open} = Games.advance_question(scope, session, nil)
    Games.QuestionTimer.stop(open.id)

    conn = put_participant_token(conn, session.join_code, token)
    {:ok, view, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

    %{view: view, session: session, participant: participant, scope: scope}
  end
end
