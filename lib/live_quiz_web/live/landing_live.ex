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
      <section class="mx-auto max-w-3xl space-y-10 py-6 text-center sm:py-12">
        <div class="space-y-4">
          <p class="inline-flex items-center gap-2 rounded-full border border-border bg-muted px-3 py-1 text-xs font-medium text-muted-foreground">
            <span aria-hidden="true">⚡</span> Quizzes ao vivo, sem instalar nada
          </p>

          <h1 class="text-4xl font-semibold tracking-tight text-balance sm:text-5xl">
            Crie quizzes e jogue em tempo real
          </h1>

          <p class="mx-auto max-w-xl text-base text-pretty text-muted-foreground sm:text-lg">
            Monte perguntas com alternativas, convide a turma e acompanhe as respostas
            acontecendo ao vivo. Sem instalar nada: basta um navegador.
          </p>
        </div>

        <div class="flex flex-col items-stretch gap-3 sm:flex-row sm:justify-center">
          <.button navigate={~p"/users/register"} size="lg">
            Criar conta
          </.button>

          <.button navigate={~p"/users/log-in"} variant="outline" size="lg">
            Entrar
          </.button>
        </div>

        <dl class="grid gap-4 text-left sm:grid-cols-3">
          <div
            :for={{title, detail} <- highlights()}
            class="rounded-lg border border-border bg-card p-5"
          >
            <dt class="text-sm font-medium">{title}</dt>
            <dd class="mt-1 text-sm text-muted-foreground">{detail}</dd>
          </div>
        </dl>
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

  # What a visitor needs to know before signing up, in the order the product
  # actually happens: you write the quiz, people join with a code, the room
  # scores as it goes.
  defp highlights do
    [
      {"Monte em minutos", "Perguntas com alternativas, tempo por pergunta e ordem na mão."},
      {"Entrada por código", "A turma entra pelo navegador com um código de seis caracteres."},
      {"Ranking ao vivo", "Pontuação e acertos aparecem pergunta a pergunta, para todos."}
    ]
  end
end
