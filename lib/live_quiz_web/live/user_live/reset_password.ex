defmodule LiveQuizWeb.UserLive.ResetPassword do
  use LiveQuizWeb, :live_view

  alias LiveQuiz.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Redefinir senha
            <:subtitle>Escolha uma nova senha para a sua conta.</:subtitle>
          </.header>
        </div>

        <.form
          for={@form}
          id="reset_password_form"
          phx-submit="reset_password"
          phx-change="validate"
        >
          <.input
            field={@form[:password]}
            type="password"
            label="Nova senha"
            autocomplete="new-password"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirmação da nova senha"
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.button phx-disable-with="Redefinindo..." class="btn btn-primary w-full">
            Redefinir senha
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Accounts.get_user_by_reset_password_token(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "O link de redefinição é inválido ou expirou.")
         |> redirect(to: ~p"/")}

      user ->
        {:ok,
         socket
         |> assign(user: user, token: token)
         |> assign_form(Accounts.change_user_password(user, %{}, hash_password: false))}
    end
  end

  @impl true
  def handle_event("reset_password", %{"user" => user_params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, user_params) do
      {:ok, {_user, _expired_tokens}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Senha redefinida com sucesso. Entre com a nova senha.")
         |> redirect(to: ~p"/users/log-in")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      socket.assigns.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "user"))
  end
end
