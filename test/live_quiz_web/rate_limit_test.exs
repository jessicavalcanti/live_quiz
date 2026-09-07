defmodule LiveQuizWeb.RateLimitTest do
  @moduledoc """
  The budgets where they meet a request (R05).

  `async: false` on purpose: the counters are one table for the whole node, so
  a case that enforces them has to be the only case running. ExUnit runs the
  synchronous cases after every asynchronous one and one at a time, which is
  what makes a global counter mean here what the test says it means.
  """

  use LiveQuizWeb.ConnCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.RateLimit

  setup {LiveQuiz.RateLimitSetup, :enforce}

  describe "POST /api/v1/session" do
    test "recusa com 429 e Retry-After depois de gastar o orçamento da conta" do
      user = user_fixture()
      {limit, _window} = RateLimit.budget(:login_by_account)

      for _attempt <- 1..limit do
        assert json_api()
               |> post(~p"/api/v1/session", %{"email" => user.email, "password" => "errada"})
               |> json_response(401)
      end

      conn =
        post(json_api(), ~p"/api/v1/session", %{"email" => user.email, "password" => "errada"})

      assert %{"errors" => %{"code" => "rate_limited"}} = json_response(conn, 429)
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
    end

    test "não chega a conferir a senha depois de recusar" do
      user = user_fixture()
      {limit, _window} = RateLimit.budget(:login_by_account)

      for _attempt <- 1..limit do
        post(json_api(), ~p"/api/v1/session", %{"email" => user.email, "password" => "errada"})
      end

      # A senha certa também é recusada, que é a prova de que o hash não roda:
      # o orçamento é gasto na entrada, antes da coisa cara.
      assert json_api()
             |> post(~p"/api/v1/session", %{
               "email" => user.email,
               "password" => valid_user_password()
             })
             |> json_response(429)
    end

    test "conta a origem separadamente da conta" do
      {limit, _window} = RateLimit.budget(:login_by_origin)

      # Uma conta diferente a cada tentativa, então quem se esgota é a origem.
      for index <- 1..limit do
        assert json_api()
               |> post(~p"/api/v1/session", %{
                 "email" => "pessoa#{index}@example.com",
                 "password" => "errada"
               })
               |> json_response(401)
      end

      assert json_api()
             |> post(~p"/api/v1/session", %{
               "email" => "outra@example.com",
               "password" => "errada"
             })
             |> json_response(429)
    end

    test "um corpo sem e-mail não gasta o orçamento de conta nenhuma" do
      {limit, _window} = RateLimit.budget(:login_by_account)
      user = user_fixture()

      for _attempt <- 1..limit, do: post(json_api(), ~p"/api/v1/session", %{})

      assert RateLimit.peek(:login_by_account, user.email) == :ok
    end
  end

  describe "POST /api/v1/session/refresh" do
    test "recusa com 429 depois do orçamento da origem" do
      {limit, _window} = RateLimit.budget(:refresh_by_origin)

      for _attempt <- 1..limit do
        assert json_api()
               |> post(~p"/api/v1/session/refresh", %{"refresh_token" => "quebrado"})
               |> json_response(401)
      end

      assert json_api()
             |> post(~p"/api/v1/session/refresh", %{"refresh_token" => "quebrado"})
             |> json_response(429)
    end
  end

  describe "as rotas que tomam um código de sala" do
    test "consultar e entrar gastam o mesmo orçamento" do
      session = game_session_fixture()
      {limit, _window} = RateLimit.budget(:join_by_origin)

      for _attempt <- 1..limit do
        assert json_api()
               |> get(~p"/api/v1/game-sessions/#{session.join_code}")
               |> json_response(200)
      end

      # Entrar é a outra coisa que se pode fazer com um código, e sai do mesmo
      # bolso: o barato é por onde se andaria o espaço de códigos.
      conn =
        post(json_api(), ~p"/api/v1/game-sessions/#{session.join_code}/join", %{
          "nickname" => "Ana"
        })

      assert %{"errors" => %{"code" => "rate_limited"}} = json_response(conn, 429)
      assert [_retry_after] = get_resp_header(conn, "retry-after")
    end
  end

  describe "POST /api/v1/game-sessions/:code/answers" do
    setup :playing_match

    test "recusa quem responde demais sem travar a sala", context do
      %{session: session, token: token, options: [option | _rest]} = context
      {other, other_token} = credentialed_participant_fixture(session, %{nickname: "Bruno"})
      {limit, _window} = RateLimit.budget(:answer_by_participation)

      for _attempt <- 1..limit do
        assert answer(token, session, option.id) |> json_response(201)
      end

      assert answer(token, session, option.id) |> json_response(429)

      # A regra que o review pediu pelo nome: um participante não custa à sala
      # o direito de responder.
      assert answer(other_token, session, option.id) |> json_response(201)
      assert RateLimit.peek(:answer_by_participation, other.id) == :ok
    end
  end

  describe "POST /users/log-in" do
    test "recusa como recusa uma senha errada, sem dizer que é a conta", %{conn: conn} do
      user = user_fixture()
      {limit, _window} = RateLimit.budget(:login_by_account)

      for _attempt <- 1..limit do
        conn
        |> post(~p"/users/log-in", %{"user" => %{"email" => user.email, "password" => "errada"}})
        |> response(302)
      end

      refused =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      # Mesma página, mesma mensagem: um formulário que dissesse "muitas
      # tentativas para este endereço" teria respondido que ele existe.
      assert redirected_to(refused) == ~p"/users/log-in"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) == "E-mail ou senha inválidos"
      refute get_session(refused, :user_token)
    end
  end

  describe "a página de esqueci minha senha" do
    test "para de enviar e-mail e continua dizendo a mesma coisa", %{conn: conn} do
      user = user_fixture()
      # Criar a conta já mandou um e-mail. Sem esvaziar a caixa, cada asserção
      # abaixo confirmaria o e-mail anterior e a última encontraria o que
      # deveria não existir.
      flush_emails()

      {limit, _window} = RateLimit.budget(:password_reset_by_account)

      for _attempt <- 1..limit do
        {:ok, live, _html} = live(conn, ~p"/users/reset-password")

        live
        |> form("#forgot_password_form", user: %{email: user.email})
        |> render_submit()

        assert_email_sent()
      end

      {:ok, live, _html} = live(conn, ~p"/users/reset-password")

      assert {:error, {:redirect, %{to: "/"}}} =
               live
               |> form("#forgot_password_form", user: %{email: user.email})
               |> render_submit()

      # Mesma página de destino, mesmo aviso — e nenhum e-mail. A resposta desta
      # tela não diz nada sobre o endereço, e um orçamento estourado não é a
      # exceção a isso.
      assert_no_email_sent()
    end

    test "conta um endereço que não existe do mesmo jeito", %{conn: conn} do
      {limit, _window} = RateLimit.budget(:password_reset_by_account)

      for _attempt <- 1..(limit + 1) do
        {:ok, live, _html} = live(conn, ~p"/users/reset-password")

        live
        |> form("#forgot_password_form", user: %{email: "ninguem@example.com"})
        |> render_submit()
      end

      # O orçamento vale para um endereço que não existe exatamente como para um
      # que existe — do contrário, quanto ele demora a esgotar já responderia.
      assert {:error, _retry_after} =
               RateLimit.peek(:password_reset_by_account, "ninguem@example.com")
    end
  end

  describe "a tela de entrar em uma sala" do
    test "recusa depois de muitos códigos e diz o que fazer", %{conn: conn} do
      {limit, _window} = RateLimit.budget(:join_by_origin)
      {:ok, live, _html} = live(conn, ~p"/join")

      for index <- 1..limit do
        live
        |> form("#join-form", join: %{code: code_of_length(index), nickname: "Ana"})
        |> render_change()
      end

      html =
        live
        |> form("#join-form", join: %{code: code_of_length(999), nickname: "Ana"})
        |> render_change()

      assert html =~ "Muitas tentativas deste dispositivo"
    end

    test "digitar um código incompleto não gasta nada", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/join")

      for partial <- ["K", "K7", "K7P", "K7P4", "K7P4Q"] do
        live
        |> form("#join-form", join: %{code: partial, nickname: "Ana"})
        |> render_change()
      end

      assert RateLimit.size() == 0
    end
  end

  describe "a origem que uma requisição é contada por" do
    test "um endereço v4 é ele mesmo" do
      assert LiveQuizWeb.RateLimit.origin({198, 51, 100, 7}) == {198, 51, 100, 7}
    end

    test "um endereço v6 é contado pelo seu /64" do
      # Um assinante recebe um /64 inteiro de rotina, então contar o endereço
      # completo não contaria nada: dois endereços da mesma casa são a mesma
      # origem.
      assert LiveQuizWeb.RateLimit.origin({0x2001, 0xDB8, 0, 1, 0, 0, 0, 1}) ==
               {0x2001, 0xDB8, 0, 1}

      assert LiveQuizWeb.RateLimit.origin({0x2001, 0xDB8, 0, 1, 0, 0, 0, 2}) ==
               LiveQuizWeb.RateLimit.origin({0x2001, 0xDB8, 0, 1, 0, 0, 0, 1})
    end

    test "sem endereço nenhum, todo mundo divide um balde" do
      # Pior que um orçamento por endereço, melhor que nenhum.
      assert LiveQuizWeb.RateLimit.origin(nil) == :unknown
    end
  end

  defp json_api, do: put_req_header(build_conn(), "accept", "application/json")

  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp playing_match(_context) do
    host = user_fixture()
    session = game_session_fixture(%{host: host, status: :in_progress})
    snapshot_fixture(session, count: 3)
    {participant, token} = credentialed_participant_fixture(session, %{nickname: "Ana"})
    {:ok, open} = Games.advance_question(Scope.for_user(host), session, nil)

    {:ok, question} = Games.get_snapshot_question(open, open.current_question_position)

    %{
      session: open,
      participant: participant,
      token: token,
      options: Enum.sort_by(question.answer_options, & &1.position)
    }
  end

  defp answer(token, %GameSession{} = session, option_id) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_api_participant(token)
    |> post(~p"/api/v1/game-sessions/#{session.join_code}/answers", %{
      "answer_option_id" => option_id
    })
  end

  # A distinct code of the full length for each attempt, so every change is a
  # lookup rather than the same one being skipped.
  defp code_of_length(index) do
    index
    |> Integer.to_string()
    |> String.pad_leading(GameSession.join_code_length(), "A")
    |> String.slice(0, GameSession.join_code_length())
  end
end
