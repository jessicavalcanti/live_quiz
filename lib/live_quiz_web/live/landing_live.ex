defmodule LiveQuizWeb.LandingLive do
  @moduledoc """
  Public entry point of the application.

  Presents the product to visitors and points them to sign up or log in.
  An authenticated visitor is sent straight to their quizzes.
  """
  use LiveQuizWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section class="mx-auto max-w-2xl space-y-8 text-center">
        <div class="space-y-4">
          <h1 class="text-3xl font-bold sm:text-4xl">
            Crie quizzes e jogue em tempo real
          </h1>

          <p class="text-base text-base-content/70 sm:text-lg">
            Monte perguntas com alternativas, convide a turma e acompanhe as respostas
            acontecendo ao vivo. Sem instalar nada: basta um navegador.
          </p>
        </div>

        <div class="flex flex-col items-stretch gap-3 sm:flex-row sm:justify-center">
          <.link navigate={~p"/users/register"} class="btn btn-primary">
            Criar conta
          </.link>

          <.link navigate={~p"/users/log-in"} class="btn btn-primary btn-soft">
            Entrar
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, push_navigate(socket, to: ~p"/quizzes")}
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Quizzes ao vivo")}
  end
end
