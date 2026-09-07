# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It is idempotent: running it twice leaves the same demo data behind, never a
# duplicate. It only runs in :dev, since the demo account must never exist in
# test or production.

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

demo_email = "demo@livequiz.dev"
demo_password = "demo123456789"

# A sala do lobby e a partida em andamento sao as duas ativas ao mesmo tempo, e
# o indice parcial so deixa uma sala ativa por host. Por isso a partida em
# andamento tem um apresentador proprio, com a mesma senha.
playing_email = "partida@livequiz.dev"

confirm_user = fn user ->
  parent = self()

  {:ok, _email} =
    Accounts.deliver_user_confirmation_instructions(user, fn token ->
      send(parent, {:confirmation_token, token})
      "http://localhost:4000/users/confirm/#{token}"
    end)

  receive do
    {:confirmation_token, token} ->
      {:ok, confirmed} = Accounts.confirm_user(token)
      confirmed
  after
    5_000 -> raise "não foi possível confirmar o usuário de demonstração"
  end
end

fetch_or_create_user = fn name, email ->
  case Accounts.get_user_by_email(email) do
    nil ->
      {:ok, user} =
        Accounts.register_user(%{
          name: name,
          email: email,
          password: demo_password,
          password_confirmation: demo_password
        })

      confirm_user.(user)

    user ->
      user
  end
end

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

if Mix.env() == :dev do
  user = fetch_or_create_user.("Pessoa de Demonstração", demo_email)

  seed_quiz = fn owner, quiz_attrs ->
    existing =
      Repo.one(
        from q in Quiz, where: q.owner_id == ^owner.id and q.title == ^quiz_attrs.title, limit: 1
      )

    quiz =
      existing ||
        %Quiz{owner_id: owner.id}
        |> Quiz.changeset(Map.take(quiz_attrs, [:title, :description]))
        |> Repo.insert!()

    for {question_attrs, question_index} <- Enum.with_index(quiz_attrs.questions) do
      position = question_index + 1

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

    quiz
  end

  join_participant = fn session, nickname ->
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
  freeze_snapshot = fn session, quiz ->
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

  record_answer = fn participant, option, answered_at ->
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

  quizzes_by_title =
    for {quiz_attrs, quiz_index} <- Enum.with_index(quizzes), into: %{} do
      quiz = seed_quiz.(user, quiz_attrs)
      IO.puts("Quiz de demonstração #{quiz_index + 1}/#{length(quizzes)}: #{quiz.title}")
      {quiz.title, quiz}
    end

  # Uma sala aguardando participantes, para abrir o lobby sem passar pelo fluxo
  # de criação. O código é fixo e a busca é pela sala ativa do host, então rodar
  # os seeds de novo reaproveita a sala em vez de esbarrar no índice único.
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

  for nickname <- demo_participants, do: join_participant.(session, nickname)

  IO.puts("Sala de demonstração aguardando participantes: código #{session.join_code}")

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

  finished_snapshot = freeze_snapshot.(finished_session, demo_quiz)
  finished_people = Enum.map(finished_participants, &join_participant.(finished_session, &1))

  for {snapshot_question, question_index} <- Enum.with_index(finished_snapshot),
      {participant, participant_index} <- Enum.with_index(finished_people) do
    # Cada pessoa erra a pergunta de índice igual ao seu, para a distribuição da
    # revelação não sair toda igual.
    chosen = if question_index == participant_index, do: 1, else: 0
    option = Enum.at(snapshot_question.answer_options, chosen)

    record_answer.(
      participant,
      option,
      DateTime.add(finished_session.started_at, question_index * 60 + participant_index + 3)
    )
  end

  IO.puts("Partida finalizada: código #{finished_session.join_code}")

  # Uma partida em andamento, parada na pergunta 1 com o prazo ainda correndo.
  playing_host = fetch_or_create_user.("Pessoa Apresentadora", playing_email)
  playing_quiz = seed_quiz.(playing_host, Enum.at(quizzes, 1))
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

  playing_snapshot = freeze_snapshot.(playing_session, playing_quiz)
  playing_people = Enum.map(playing_participants, &join_participant.(playing_session, &1))
  [open_question | _rest] = playing_snapshot

  # Duas das três pessoas já responderam: a terceira mantém a pergunta aberta,
  # em vez de disparar o encerramento por "todos responderam".
  for {participant, index} <- Enum.with_index(Enum.take(playing_people, 2)) do
    option = Enum.at(open_question.answer_options, index)
    record_answer.(participant, option, playing_session.current_question_started_at)
  end

  IO.puts("Partida em andamento: código #{playing_session.join_code}")
  IO.puts("Pronto. Entre com #{demo_email} / #{demo_password}")
  IO.puts("O apresentador da partida em andamento é #{playing_email} / #{demo_password}")
end
