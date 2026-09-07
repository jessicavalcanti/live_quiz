defmodule LiveQuiz.DemoSeed do
  @moduledoc """
  The rooms, the matches and the accounts a demonstration is shown with.

  This used to be the whole of `priv/repo/seeds.exs`, gated on `Mix.env()`.
  Inside an assembled release there is no Mix, so the demo container's
  `LiveQuiz.Release.seed/0` raised before the server came up; and even with Mix
  present, a gate on `:dev` would have seeded nothing into a demo built in
  `:prod` — the documented account simply would not exist (R47).

  So the work lives in a compiled module with no build-time dependency, and
  what decides whether it runs is `enabled?/0`, read from the environment at
  runtime. It is off unless something says otherwise, because the accounts
  below have published passwords: they belong to a demonstration and nowhere
  else. Turning them into a default that production could reach is the one
  outcome worth designing against.

  Idempotent by construction: every insert looks for what it is about to write
  and reuses it. Running it twice leaves the same data, never a duplicate.
  """

  import Ecto.Query

  alias LiveQuiz.Accounts
  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.GameSessionAnswerOption
  alias LiveQuiz.Games.GameSessionQuestion
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Question
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  @env_var "DEMO_SEED"

  @doc """
  Whether this environment asked for the demonstration data.

  `DEMO_SEED=true` and nothing else. An unset variable, an empty one or any
  other value is a no: an environment that has not asked for published
  credentials must not receive them by default.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    @env_var |> System.get_env("") |> String.trim() |> String.downcase() == "true"
  end

  @doc "The name of the variable that turns the demonstration data on."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc """
  Writes the demonstration data, or answers `:disabled` when it was not asked for.

  `run!/0` is the same thing without the gate, for the development seeds, which
  are already an explicit request.
  """
  @spec run() :: :ok | :disabled
  def run do
    if enabled?(), do: run!(), else: :disabled
  end

  @doc "Writes the demonstration data, whatever the environment says."
  @spec run!() :: :ok
  def run! do
    demo_email = "demo@livequiz.dev"
    demo_password = "demo123456789"
    playing_email = "partida@livequiz.dev"

    demo_join_code = "DEMA25"
    demo_participants = ["Ana", "Bruno", "Carla"]
    playing_join_code = "JGAND3"
    playing_participants = ["Diego", "Elisa", "Fábio"]
    finished_join_code = "FECHA4"
    finished_participants = ["Gabriel", "Helena", "Ivo"]

    quizzes = [
      %{
        title: "Capitais do Brasil",
        description: "Um passeio pelas capitais dos estados brasileiros.",
        questions: [
          %{
            text: "Qual é a capital do Amazonas?",
            options: [{"Manaus", true}, {"Belém", false}, {"Boa Vista", false}, {"Palmas", false}]
          },
          %{
            text: "Qual é a capital da Bahia?",
            options: [
              {"Salvador", true},
              {"Recife", false},
              {"Maceió", false},
              {"Aracaju", false}
            ]
          },
          %{
            text: "Qual é a capital do Paraná?",
            options: [
              {"Curitiba", true},
              {"Florianópolis", false},
              {"Porto Alegre", false},
              {"Londrina", false}
            ]
          }
        ]
      },
      %{
        title: "Sistema solar",
        description: "Perguntas rápidas sobre os planetas e seus vizinhos.",
        questions: [
          %{
            text: "Qual é o maior planeta do sistema solar?",
            options: [{"Júpiter", true}, {"Saturno", false}, {"Netuno", false}, {"Terra", false}]
          },
          %{
            text: "Qual planeta é conhecido como planeta vermelho?",
            options: [{"Marte", true}, {"Vênus", false}, {"Mercúrio", false}, {"Urano", false}]
          },
          %{
            text: "Quantas luas a Terra possui?",
            options: [{"Uma", true}, {"Duas", false}, {"Nenhuma", false}, {"Quatro", false}]
          }
        ]
      }
    ]

    user = fetch_or_create_user("Pessoa de Demonstração", demo_email, demo_password)

    quizzes_by_title =
      for {quiz_attrs, quiz_index} <- Enum.with_index(quizzes), into: %{} do
        quiz = seed_quiz(user, quiz_attrs)
        IO.puts("Quiz de demonstração #{quiz_index + 1}/#{length(quizzes)}: #{quiz.title}")
        {quiz.title, quiz}
      end

    # Uma sala aguardando participantes, para abrir o lobby sem passar pelo fluxo
    # de criação. O código é fixo e a busca é pela sala ativa do host, então rodar
    # os seeds de novo reaproveita a sala em vez de esbarrar no índice único.

    waiting_room(user, quizzes_by_title, demo_join_code, demo_participants)
    finished_match(user, quizzes_by_title, finished_join_code, finished_participants)
    playing_match(playing_email, quizzes, playing_join_code, playing_participants, demo_password)

    IO.puts("Pronto. Entre com #{demo_email} / #{demo_password}")
    IO.puts("O apresentador da partida em andamento é #{playing_email} / #{demo_password}")

    :ok
  end

  # Uma sala parada no lobby, esperando gente: é o que a tela do host mostra
  # antes de a partida começar.
  defp waiting_room(user, quizzes_by_title, demo_join_code, demo_participants) do
    demo_quiz = quizzes_by_title["Capitais do Brasil"]
    active_statuses = GameSession.active_statuses()

    session =
      Repo.one(
        from s in GameSession,
          where: s.host_id == ^user.id and s.status in ^active_statuses,
          limit: 1
      ) ||
        %GameSession{host_id: user.id, quiz_id: demo_quiz.id}
        |> GameSession.create_changeset(%{quiz_title: demo_quiz.title, join_code: demo_join_code})
        |> Repo.insert!()

    for nickname <- demo_participants, do: join_participant(session, nickname)

    IO.puts("Sala de demonstração aguardando participantes: código #{session.join_code}")

    :ok
  end

  defp finished_match(user, quizzes_by_title, finished_join_code, finished_participants) do
    demo_quiz = quizzes_by_title["Capitais do Brasil"]
    # Uma partida finalizada, com o snapshot e todas as respostas registradas: é o
    # que a fase 4 vai ler como histórico. Nasce já finalizada porque o host acima
    # só pode ter uma sala ativa por vez.
    finished_session =
      Repo.one(
        from s in GameSession,
          where: s.host_id == ^user.id and s.join_code == ^finished_join_code,
          limit: 1
      ) ||
        (
          started_at = DateTime.add(DateTime.utc_now(), -40, :minute)

          %GameSession{host_id: user.id, quiz_id: demo_quiz.id}
          |> GameSession.create_changeset(%{
            quiz_title: demo_quiz.title,
            join_code: finished_join_code,
            question_duration_seconds: 30
          })
          |> Ecto.Changeset.apply_changes()
          |> GameSession.status_changeset(:in_progress, at: started_at)
          |> Ecto.Changeset.apply_changes()
          |> GameSession.status_changeset(:finished,
            at: DateTime.add(started_at, 10, :minute)
          )
          |> Ecto.Changeset.change(
            current_question_position: 3,
            current_question_started_at: DateTime.add(started_at, 9, :minute),
            current_question_ends_at: DateTime.add(started_at, 9 * 60 + 30, :second),
            current_question_closed_at: DateTime.add(started_at, 9 * 60 + 30, :second)
          )
          |> Repo.insert!()
        )

    finished_snapshot = freeze_snapshot(finished_session, demo_quiz)
    finished_people = Enum.map(finished_participants, &join_participant(finished_session, &1))

    for {snapshot_question, question_index} <- Enum.with_index(finished_snapshot),
        {participant, participant_index} <- Enum.with_index(finished_people) do
      # Cada pessoa erra a pergunta de índice igual ao seu, para a distribuição da
      # revelação não sair toda igual.
      chosen = if question_index == participant_index, do: 1, else: 0
      option = Enum.at(snapshot_question.answer_options, chosen)

      record_answer(
        participant,
        option,
        DateTime.add(finished_session.started_at, question_index * 60 + participant_index + 3)
      )
    end

    IO.puts("Partida finalizada: código #{finished_session.join_code}")

    :ok
  end

  defp playing_match(playing_email, quizzes, playing_join_code, playing_participants, password) do
    # Uma partida em andamento, parada na pergunta 1 com o prazo ainda correndo.
    playing_host = fetch_or_create_user("Pessoa Apresentadora", playing_email, password)
    playing_quiz = seed_quiz(playing_host, Enum.at(quizzes, 1))
    playing_duration = 60

    playing_session =
      Repo.one(
        from s in GameSession,
          where: s.host_id == ^playing_host.id and s.join_code == ^playing_join_code,
          limit: 1
      ) ||
        (
          started_at = DateTime.utc_now()

          %GameSession{host_id: playing_host.id, quiz_id: playing_quiz.id}
          |> GameSession.create_changeset(%{
            quiz_title: playing_quiz.title,
            join_code: playing_join_code,
            question_duration_seconds: playing_duration
          })
          |> Ecto.Changeset.apply_changes()
          |> GameSession.status_changeset(:in_progress, at: started_at)
          |> Ecto.Changeset.change(
            current_question_position: 1,
            current_question_started_at: started_at,
            current_question_ends_at: DateTime.add(started_at, playing_duration)
          )
          |> Repo.insert!()
        )

    # Rodar os seeds de novo empurra o prazo para a frente: sem isso a pergunta
    # sobe com o prazo vencido e o timer da F3-05 a encerra na hora.
    playing_session =
      if GameSession.question_open?(playing_session) and
           DateTime.compare(playing_session.current_question_ends_at, DateTime.utc_now()) != :gt do
        now = DateTime.utc_now()

        playing_session
        |> Ecto.Changeset.change(
          current_question_started_at: now,
          current_question_ends_at: DateTime.add(now, playing_session.question_duration_seconds)
        )
        |> Repo.update!()
      else
        playing_session
      end

    playing_snapshot = freeze_snapshot(playing_session, playing_quiz)
    playing_people = Enum.map(playing_participants, &join_participant(playing_session, &1))
    [open_question | _rest] = playing_snapshot

    # Duas das três pessoas já responderam: a terceira mantém a pergunta aberta,
    # em vez de disparar o encerramento por "todos responderam".
    for {participant, index} <- Enum.with_index(Enum.take(playing_people, 2)) do
      option = Enum.at(open_question.answer_options, index)
      record_answer(participant, option, playing_session.current_question_started_at)
    end

    IO.puts("Partida em andamento: código #{playing_session.join_code}")

    :ok
  end

  defp seed_quiz(owner, quiz_attrs) do
    existing =
      Repo.one(
        from q in Quiz,
          where: q.owner_id == ^owner.id and q.title == ^quiz_attrs.title,
          limit: 1
      )

    quiz =
      existing ||
        %Quiz{owner_id: owner.id}
        |> Quiz.changeset(Map.take(quiz_attrs, [:title, :description]))
        |> Repo.insert!()

    for {question_attrs, question_index} <- Enum.with_index(quiz_attrs.questions) do
      seed_question(quiz, question_attrs, question_index + 1)
    end

    quiz
  end

  defp seed_question(quiz, question_attrs, position) do
    already_there? =
      Repo.exists?(from q in Question, where: q.quiz_id == ^quiz.id and q.position == ^position)

    unless already_there? do
      options =
        for {{text, is_correct}, option_index} <- Enum.with_index(question_attrs.options) do
          %{text: text, position: option_index + 1, is_correct: is_correct}
        end

      %Question{quiz_id: quiz.id}
      |> Question.changeset(%{
        text: question_attrs.text,
        position: position,
        answer_options: options
      })
      |> Repo.insert!()
    end
  end

  defp join_participant(session, nickname) do
    normalized = Participant.normalize_nickname(nickname)

    Repo.one(
      from p in Participant,
        where: p.game_session_id == ^session.id and p.nickname_normalized == ^normalized,
        limit: 1
    ) ||
      %Participant{
        game_session_id: session.id,
        access_token_hash: :crypto.hash(:sha256, "demo-participant:#{session.id}:#{normalized}"),
        joined_at: DateTime.truncate(DateTime.utc_now(), :second)
      }
      |> Participant.join_changeset(%{nickname: nickname})
      |> Repo.insert!()
  end

  # Congela o conteúdo do quiz na partida. A criação de verdade nasce na F3-02,
  # dentro da transação que inicia a sala; aqui é só o dado de desenvolvimento.
  defp freeze_snapshot(session, quiz) do
    options_in_order = from o in AnswerOption, order_by: [asc: o.position]

    questions =
      Repo.all(
        from q in Question,
          where: q.quiz_id == ^quiz.id,
          order_by: [asc: q.position],
          preload: [answer_options: ^options_in_order]
      )

    for question <- questions do
      snapshot_question =
        Repo.one(
          from q in GameSessionQuestion,
            where: q.game_session_id == ^session.id and q.position == ^question.position,
            limit: 1
        ) ||
          %GameSessionQuestion{game_session_id: session.id, question_id: question.id}
          |> GameSessionQuestion.changeset(%{
            position: question.position,
            text: question.text
          })
          |> Repo.insert!()

      options =
        for option <- question.answer_options do
          Repo.one(
            from o in GameSessionAnswerOption,
              where:
                o.game_session_question_id == ^snapshot_question.id and
                  o.position == ^option.position,
              limit: 1
          ) ||
            %GameSessionAnswerOption{
              game_session_question_id: snapshot_question.id,
              original_answer_option_id: option.id
            }
            |> GameSessionAnswerOption.changeset(%{
              text: option.text,
              position: option.position,
              is_correct: option.is_correct
            })
            |> Repo.insert!()
        end

      %{snapshot_question | answer_options: options}
    end
  end

  defp record_answer(participant, option, answered_at) do
    Repo.one(
      from a in Answer,
        where:
          a.participant_id == ^participant.id and
            a.game_session_question_id == ^option.game_session_question_id,
        limit: 1
    ) ||
      %Answer{}
      |> Answer.changeset(%{
        game_session_id: participant.game_session_id,
        game_session_question_id: option.game_session_question_id,
        participant_id: participant.id,
        game_session_answer_option_id: option.id,
        answered_at: answered_at
      })
      |> Repo.insert!()
  end

  defp fetch_or_create_user(name, email, password) do
    case Accounts.get_user_by_email(email) do
      nil ->
        {:ok, user} =
          Accounts.register_user(%{
            name: name,
            email: email,
            password: password,
            password_confirmation: password
          })

        confirm(user)

      user ->
        user
    end
  end

  # The account is confirmed by issuing its token and consuming it, without
  # asking anybody to deliver an email. Going through the mailer made the demo
  # data depend on an SMTP server being up before the seed ran — a dependency a
  # demonstration should not have, and the reason the packaged release could not
  # seed itself without one.
  defp confirm(user) do
    {token, user_token} = LiveQuiz.Accounts.UserToken.build_email_token(user, "confirm")
    Repo.insert!(user_token)

    {:ok, confirmed} = Accounts.confirm_user(token)

    confirmed
  end
end
