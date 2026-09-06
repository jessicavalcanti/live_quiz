defmodule LiveQuizWeb.Api.AssignScope do
  @moduledoc """
  Assigns `conn.assigns.current_scope` from the user carried by the JWT.

  This is what makes the API call the contexts exactly like the LiveViews do:
  both hand over a `LiveQuiz.Accounts.Scope`, so authorization lives in a single
  place.
  """

  @behaviour Plug

  alias LiveQuiz.Accounts.Scope

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    user = Guardian.Plug.current_resource(conn)
    Plug.Conn.assign(conn, :current_scope, Scope.for_user(user))
  end
end
