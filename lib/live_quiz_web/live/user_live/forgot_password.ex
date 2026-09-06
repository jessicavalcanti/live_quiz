defmodule LiveQuizWeb.UserLive.ForgotPassword do
  use LiveQuizWeb, :live_view

  alias LiveQuiz.Accounts

  # The same message is always shown, so the form never reveals whether an
  # email address is registered.
  @info "Se esse e-mail estiver cadastrado, você receberá em instantes as instruções para redefinir sua senha."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Esqueci minha senha
            <:subtitle>Enviaremos um link de redefinição para o seu e-mail.</:subtitle>
          </.header>
        </div>

        <.form for={@form} id="forgot_password_form" phx-submit="send_instructions">
          <.input
            field={@form[:email]}
            type="email"
            label="E-mail"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button phx-disable-with="Enviando..." class="btn btn-primary w-full">
            Enviar instruções
          </.button>
        </.form>

        <p class="text-center text-sm mt-4">
          <.link navigate={~p"/users/log-in"} class="font-semibold hover:underline">Entrar</.link>
          |
          <.link navigate={~p"/users/register"} class="font-semibold hover:underline">
            Cadastrar-se
          </.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :form, to_form(%{}, as: "user"))}
  end

  @impl true
  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_reset_password_instructions(
        user,
        &url(~p"/users/reset-password/#{&1}")
      )
    end

    {:noreply,
     socket
     |> put_flash(:info, @info)
     |> redirect(to: ~p"/")}
  end
end
