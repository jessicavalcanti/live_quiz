defmodule LiveQuizWeb.Api.AssignScopeTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuizWeb.Api.AssignScope

  test "init/1 keeps the options untouched" do
    assert AssignScope.init([]) == []
  end

  test "assigns the scope of the user loaded by Guardian" do
    user = user_fixture()

    conn =
      build_conn()
      |> Guardian.Plug.put_current_resource(user)
      |> AssignScope.call([])

    assert conn.assigns.current_scope == Scope.for_user(user)
  end

  test "assigns no scope when no resource was loaded" do
    conn = AssignScope.call(build_conn(), [])

    assert conn.assigns.current_scope == nil
  end
end
