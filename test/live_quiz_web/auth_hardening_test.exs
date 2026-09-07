defmodule LiveQuizWeb.AuthHardeningTest do
  @moduledoc """
  What a request that is not a form can do to the authentication flow, and what
  reaches the log.

  Regressions for R04 and R06 of the review. A form posts two strings; a request
  written by hand posts whatever it likes, and every place that destructured it
  turned "this is not a login" into a 500. And filtering parameters keeps a
  password out of the log while doing nothing for a token that travels in the
  path.
  """

  use LiveQuizWeb.ConnCase, async: true

  import Ecto.Query
  import LiveQuiz.AccountsFixtures
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts
  alias LiveQuiz.Repo
  alias LiveQuizWeb.RequestLogging
  alias LiveQuizWeb.UserAuth

  describe "entrar com um corpo que não é um formulário" do
    test "sem usuário nenhum, recusa em vez de estourar", %{conn: conn} do
      conn = post(conn, ~p"/users/log-in", %{})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "inválidos"
    end

    test "sem e-mail e sem senha, recusa", %{conn: conn} do
      conn = post(conn, ~p"/users/log-in", %{"user" => %{}})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "inválidos"
    end

    test "com senha em forma de mapa ou lista, recusa", %{conn: conn} do
      for password <- [%{"a" => "b"}, ["a"], 1] do
        conn =
          post(build_conn(), ~p"/users/log-in", %{
            "user" => %{"email" => "a@b.c", "password" => password}
          })

        assert redirected_to(conn) == ~p"/users/log-in"
      end

      assert conn
    end

    test "com e-mail que não é texto, não tenta ecoá-lo de volta", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{"user" => %{"email" => %{"x" => 1}, "password" => "x"}})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == ""
    end

    test "o contexto devolve nil para credenciais de forma impossível" do
      assert Accounts.get_user_by_email_and_password(%{}, "senha") == nil
      assert Accounts.get_user_by_email_and_password("a@b.c", ["senha"]) == nil
      assert Accounts.get_user_by_email_and_password(nil, nil) == nil
    end

    test "e continua entrando com credenciais válidas", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
    end
  end

  describe "trocar a senha depois de a janela de sudo fechar" do
    setup :register_and_log_in_user

    test "manda reautenticar em vez de estourar", %{conn: conn, user: user} do
      expire_sudo(user)

      conn =
        post(conn, ~p"/users/update-password", %{
          "user" => %{
            "password" => "nova senha valida",
            "password_confirmation" => "nova senha valida"
          }
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Confirme sua senha"

      # E a senha antiga continua valendo: a recusa não escreveu nada.
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "uma senha inválida dentro da janela é erro de formulário, não 500", %{conn: conn} do
      conn =
        post(conn, ~p"/users/update-password", %{
          "user" => %{"password" => "curta", "password_confirmation" => "curta"}
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Não foi possível alterar a senha"
    end

    test "um corpo que não é um formulário é recusado", %{conn: conn} do
      conn = post(conn, ~p"/users/update-password", %{})

      assert redirected_to(conn) == ~p"/users/settings"
    end
  end

  describe "a tela de configurações depois de a janela fechar" do
    setup :register_and_log_in_user

    test "recusa a montagem", %{conn: conn, user: user} do
      expire_sudo(user)

      assert {:error, {:redirect, %{to: "/users/log-in", flash: flash}}} =
               live(conn, ~p"/users/settings")

      assert flash["error"] =~ "Confirme sua senha"
    end

    test "abre normalmente dentro da janela", %{conn: conn} do
      assert {:ok, _lv, html} = live(conn, ~p"/users/settings")
      assert html =~ "Configurações da conta"
    end
  end

  describe "a janela de sudo" do
    test "é uma só: o mount e os eventos perguntam a mesma coisa" do
      # O defeito era a divergência. A montagem usava dez minutos e os eventos
      # vinte, então existia uma faixa em que uma aba era recusada na entrada e
      # ainda assim conseguia agir (R06).
      assert Accounts.sudo_window_minutes() == 10

      inside = %LiveQuiz.Accounts.User{authenticated_at: minutes_ago(9)}
      outside = %LiveQuiz.Accounts.User{authenticated_at: minutes_ago(11)}

      assert UserAuth.ensure_sudo(inside) == :ok
      assert UserAuth.ensure_sudo(outside) == {:error, :sudo_required}

      assert Accounts.sudo_mode?(inside)
      refute Accounts.sudo_mode?(outside)
    end

    test "sem autenticação nenhuma, não há sudo" do
      assert UserAuth.ensure_sudo(nil) == {:error, :sudo_required}
      assert UserAuth.ensure_sudo(%LiveQuiz.Accounts.User{}) == {:error, :sudo_required}
    end
  end

  describe "o que chega ao log" do
    test "os caminhos que carregam credencial não são registrados" do
      for prefix <- RequestLogging.secret_prefixes() do
        assert RequestLogging.level(%Plug.Conn{path_info: prefix ++ ["um-token"]}) == false
      end
    end

    test "o prefixo sem o token continua sendo registrado" do
      for prefix <- RequestLogging.secret_prefixes() do
        assert RequestLogging.level(%Plug.Conn{path_info: prefix}) == :info
      end
    end

    test "as demais rotas continuam sendo registradas" do
      for path <- [[], ["quizzes"], ["users", "log-in"], ["api", "v1", "session"]] do
        assert RequestLogging.level(%Plug.Conn{path_info: path}) == :info
      end
    end

    test "a senha enviada num login não aparece no log", %{conn: conn} do
      user = user_fixture()
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log(fn ->
          conn
          |> post(~p"/users/log-in", %{
            "user" => %{"email" => user.email, "password" => valid_user_password()}
          })
          |> response(302)
        end)

      refute log =~ valid_user_password()
      assert log =~ "[FILTERED]"
    end
  end

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes, :minute)

  # Empurra o instante da autenticação para fora da janela, que é o que o tempo
  # faz enquanto a aba fica aberta.
  defp expire_sudo(user) do
    past = DateTime.add(DateTime.utc_now(:second), -(Accounts.sudo_window_minutes() + 1), :minute)

    Repo.update_all(
      from(t in LiveQuiz.Accounts.UserToken, where: t.user_id == ^user.id),
      set: [authenticated_at: past]
    )
  end
end
