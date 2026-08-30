defmodule LiveQuizWeb.UserLive.Login do
  use LiveQuizWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>Entrar</p>
            <:subtitle>
              <%= if @current_scope do %>
                Confirme sua senha para continuar com esta ação sensível na sua conta.
              <% else %>
                Ainda não tem conta? <.link
                  navigate={~p"/users/register"}
                  class="font-semibold text-brand hover:underline"
                  phx-no-format
                >Cadastre-se</.link> agora.
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <div :if={local_mail_adapter?()} class="alert alert-info">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>Você está usando o adaptador local de e-mail.</p>
            <p>
              Para ver os e-mails enviados, acesse <.link href="/dev/mailbox" class="underline">a caixa de entrada</.link>.
            </p>
          </div>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form"
          action={~p"/users/log-in"}
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="E-mail"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={f[:password]}
            type="password"
            label="Senha"
            autocomplete="current-password"
            spellcheck="false"
            required
          />
          <.button class="btn btn-primary w-full" name={f[:remember_me].name} value="true">
            Entrar e manter conectado <span aria-hidden="true">→</span>
          </.button>
          <.button class="btn btn-primary btn-soft w-full mt-2">
            Entrar apenas desta vez
          </.button>
        </.form>

        <p class="text-center text-sm">
          <.link navigate={~p"/users/reset-password"} class="font-semibold hover:underline">
            Esqueci minha senha
          </.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  defp local_mail_adapter? do
    Application.get_env(:live_quiz, LiveQuiz.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
