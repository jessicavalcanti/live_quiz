defmodule LiveQuizWeb.UserLive.Login do
  use LiveQuizWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <.alert :if={local_mail_adapter?()} variant="info">
          <span><.icon name="hero-information-circle" class="size-4" /></span>
          <.alert_title>Adaptador local de e-mail</.alert_title>
          <.alert_description>
            Para ver os e-mails enviados, acesse <.link
              href="/dev/mailbox"
              class="font-medium underline underline-offset-4"
            >
              a caixa de entrada
            </.link>.
          </.alert_description>
        </.alert>

        <.card>
          <.card_header class="text-center">
            <.card_title>Entrar</.card_title>
            <.card_description>
              <%= if @current_scope do %>
                Confirme sua senha para continuar com esta ação sensível na sua conta.
              <% else %>
                Ainda não tem conta? <.link
                  navigate={~p"/users/register"}
                  class="font-medium text-foreground underline underline-offset-4"
                  phx-no-format
                >Cadastre-se</.link> agora.
              <% end %>
            </.card_description>
          </.card_header>

          <.card_content>
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
                reveal_password
                required
              />
              <.button class="w-full" name={f[:remember_me].name} value="true">
                Entrar e manter conectado <span aria-hidden="true">→</span>
              </.button>
              <.button variant="secondary" class="mt-2 w-full">
                Entrar apenas desta vez
              </.button>
            </.form>
          </.card_content>

          <.card_footer class="justify-center">
            <.link
              navigate={~p"/users/reset-password"}
              class="text-sm font-medium text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
            >
              Esqueci minha senha
            </.link>
          </.card_footer>
        </.card>
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
