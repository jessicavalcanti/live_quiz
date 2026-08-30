defmodule LiveQuizWeb.QuizzesLive do
  @moduledoc """
  Landing spot for authenticated users.

  Story F1-09 replaces this placeholder with the real quiz dashboard; for now it
  only gives the authenticated routes a destination to point at.
  """
  use LiveQuizWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Meus quizzes
        <:subtitle>Seus quizzes aparecerão aqui.</:subtitle>
      </.header>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Meus quizzes")}
  end
end
