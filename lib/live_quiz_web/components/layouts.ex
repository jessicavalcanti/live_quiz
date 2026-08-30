defmodule LiveQuizWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use LiveQuizWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar gap-2 px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <.link navigate={home_path(@current_scope)} class="text-lg font-semibold">
          LiveQuiz
        </.link>
      </div>

      <nav class="flex-none" aria-label="Menu do usuário">
        <ul class="flex items-center gap-2 sm:gap-4">
          <%= if @current_scope do %>
            <li class="hidden text-sm font-medium sm:block">
              {@current_scope.user.name}
            </li>
            <li>
              <.link navigate={~p"/users/settings"} class="btn btn-ghost btn-sm">
                Minha conta
              </.link>
            </li>
            <li>
              <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-sm">
                Sair
              </.link>
            </li>
          <% else %>
            <li>
              <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm">
                Entrar
              </.link>
            </li>
            <li>
              <.link navigate={~p"/users/register"} class="btn btn-primary btn-sm">
                Criar conta
              </.link>
            </li>
          <% end %>
          <li>
            <.theme_toggle />
          </li>
        </ul>
      </nav>
    </header>

    <main class="px-4 py-12 sm:px-6 sm:py-20 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        <.unconfirmed_email_notice current_scope={@current_scope} />
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  defp home_path(%{user: %{}}), do: ~p"/quizzes"
  defp home_path(_current_scope), do: ~p"/"

  @doc """
  Reminds the user to confirm their e-mail address.

  The reminder never blocks navigation: confirming is encouraged, not required
  (see AD-03 of the phase 1 epic).
  """
  attr :current_scope, :map, default: nil

  def unconfirmed_email_notice(%{current_scope: %{user: %{confirmed_at: nil}}} = assigns) do
    ~H"""
    <div class="alert alert-warning" role="status">
      <.icon name="hero-envelope" class="size-5 shrink-0" />
      <span>
        Confirme seu e-mail para manter sua conta segura. Enviamos um link para {@current_scope.user.email}.
      </span>
    </div>
    """
  end

  def unconfirmed_email_notice(assigns) do
    ~H"""
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Usar o tema do sistema"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Usar o tema claro"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Usar o tema escuro"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
