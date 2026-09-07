defmodule LiveQuizWeb.UserLive.ForgotPassword do
  @moduledoc """
  Asks for a reset link.

  Every submission that gets past here costs an email, which is the one thing
  this application does that is expensive somewhere else, so the form is
  budgeted by origin and by the address it names (R05). A spent budget shows
  the very same message as a successful one: the whole design of this page is
  that its answer says nothing about the address, and a distinct "too many
  attempts for this address" would say a great deal.
  """

  use LiveQuizWeb, :live_view

  alias LiveQuiz.Accounts
  alias LiveQuiz.RateLimit

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
    {:ok,
     socket
     |> LiveQuizWeb.RateLimit.assign_origin()
     |> assign(:form, to_form(%{}, as: "user"))}
  end

  @impl true
  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket)
      when is_binary(email) do
    if budget_left?(socket, email) do
      deliver_instructions(email)
    end

    {:noreply,
     socket
     |> put_flash(:info, @info)
     |> redirect(to: ~p"/")}
  end

  def handle_event("send_instructions", _params, socket) do
    {:noreply,
     socket
     |> put_flash(:info, @info)
     |> redirect(to: ~p"/")}
  end

  # Both budgets are spent before the account is looked up, so the count does
  # not depend on whether the address exists — a limiter that only counted real
  # addresses would answer "this one is real" by how long it took to say no.
  defp budget_left?(socket, email) do
    by_origin = LiveQuizWeb.RateLimit.hit(socket, :password_reset_by_origin)
    by_account = RateLimit.hit(:password_reset_by_account, normalize(email))

    by_origin == :ok and by_account == :ok
  end

  defp normalize(email), do: email |> String.trim() |> String.downcase()

  defp deliver_instructions(email) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_reset_password_instructions(
        user,
        &url(~p"/users/reset-password/#{&1}")
      )
    end
  end
end
