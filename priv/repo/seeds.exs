# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It is idempotent: running it twice leaves the same demo data behind, never a
# duplicate. It only runs in :dev, since the demo account must never exist in
# test or production.

import Ecto.Query

alias LiveQuiz.Accounts
alias LiveQuiz.Games.GameSession
alias LiveQuiz.Games.Participant
alias LiveQuiz.Quizzes.Question
alias LiveQuiz.Quizzes.Quiz
alias LiveQuiz.Repo

demo_email = "demo@livequiz.dev"
demo_password = "demo123456789"

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

fetch_or_create_user = fn ->
  case Accounts.get_user_by_email(demo_email) do
    nil ->
      {:ok, user} =
        Accounts.register_user(%{
          name: "Pessoa de Demonstração",
          email: demo_email,
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
  user = fetch_or_create_user.()

  for {quiz_attrs, quiz_index} <- Enum.with_index(quizzes) do
    existing =
      Repo.one(
        from q in Quiz, where: q.owner_id == ^user.id and q.title == ^quiz_attrs.title, limit: 1
      )

    quiz =
      existing ||
        %Quiz{owner_id: user.id}
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

    IO.puts("Quiz de demonstração #{quiz_index + 1}/#{length(quizzes)}: #{quiz.title}")
  end

  # Uma sala aguardando participantes, para abrir o lobby sem passar pelo fluxo
  # de criação. O código é fixo e a busca é pela sala ativa do host, então rodar
  # os seeds de novo reaproveita a sala em vez de esbarrar no índice único.
  demo_quiz =
    Repo.one(from q in Quiz, where: q.owner_id == ^user.id, order_by: [asc: q.id], limit: 1)

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

  for nickname <- demo_participants do
    normalized = Participant.normalize_nickname(nickname)

    already_there? =
      Repo.exists?(
        from p in Participant,
          where: p.game_session_id == ^session.id and p.nickname_normalized == ^normalized
      )

    unless already_there? do
      %Participant{
        game_session_id: session.id,
        access_token_hash: :crypto.hash(:sha256, "demo-participant:#{session.id}:#{normalized}"),
        joined_at: DateTime.truncate(DateTime.utc_now(), :second)
      }
      |> Participant.join_changeset(%{nickname: nickname})
      |> Repo.insert!()
    end
  end

  IO.puts("Sala de demonstração aguardando participantes: código #{session.join_code}")
  IO.puts("Pronto. Entre com #{demo_email} / #{demo_password}")
end
