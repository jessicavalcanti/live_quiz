defmodule LiveQuizWeb.UserLive.Confirmation do
  use LiveQuizWeb, :live_view

  alias LiveQuiz.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Confirmar conta
            <:subtitle>Confirme seu e-mail para concluir o cadastro.</:subtitle>
          </.header>
        </div>

        <.form for={@form} id="confirmation_form" phx-submit="confirm" phx-mounted={JS.focus_first()}>
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button phx-disable-with="Confirmando..." class="btn btn-primary w-full">
            Confirmar minha conta
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    form = to_form(%{"token" => token}, as: "user")
    {:ok, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("confirm", %{"user" => %{"token" => token}}, socket) do
    case Accounts.confirm_user(token) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conta confirmada com sucesso.")
         |> redirect(to: ~p"/")}

      :error ->
        # The account may have been confirmed already, either by this same link
        # being visited twice or by another device.
        case socket.assigns.current_scope do
          %{user: %{confirmed_at: confirmed_at}} when not is_nil(confirmed_at) ->
            {:noreply, redirect(socket, to: ~p"/")}

          _ ->
            {:noreply,
             socket
             |> put_flash(:error, "O link de confirmação é inválido ou expirou.")
             |> redirect(to: ~p"/")}
        end
    end
  end
end
