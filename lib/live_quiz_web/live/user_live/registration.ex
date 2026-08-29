defmodule LiveQuizWeb.UserLive.Registration do
  use LiveQuizWeb, :live_view

  alias LiveQuiz.Accounts
  alias LiveQuiz.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Criar uma conta
            <:subtitle>
              Já tem cadastro?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Entre
              </.link>
              na sua conta agora.
            </:subtitle>
          </.header>
        </div>

        <.form
          for={@form}
          id="registration_form"
          action={~p"/users/log-in?_action=registered"}
          method="post"
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={@form[:name]}
            type="text"
            label="Nome"
            autocomplete="name"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:email]}
            type="email"
            label="E-mail"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Senha"
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirmação de senha"
            autocomplete="new-password"
            spellcheck="false"
            required
          />

          <.button phx-disable-with="Criando conta..." class="btn btn-primary w-full">
            Criar conta
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: LiveQuizWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{})

    {:ok,
     socket
     |> assign(:trigger_submit, false)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_user_confirmation_instructions(
            user,
            &url(~p"/users/confirm/#{&1}")
          )

        # The form is submitted for real to the session controller, which logs
        # the user in right away — the confirmation email does not block access.
        {:noreply, assign(socket, :trigger_submit, true)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "user"))
  end
end
