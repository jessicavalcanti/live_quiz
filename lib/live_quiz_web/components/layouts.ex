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
    <header class="sticky top-0 z-40 border-b border-border bg-background/80 backdrop-blur-md">
      <div class="mx-auto flex h-14 w-full max-w-7xl items-center gap-2 px-3 sm:px-4 lg:px-6">
        <div class="flex-1">
          <.link
            id="app-brand"
            navigate={home_path(@current_scope)}
            class="inline-flex items-center rounded-md text-base font-semibold tracking-tight focus-visible:ring-[3px] focus-visible:ring-ring/50 focus-visible:outline-hidden"
          >
            <.brand />
          </.link>
        </div>

        <nav class="flex-none" aria-label="Menu do usuário">
          <ul class="flex items-center gap-1 sm:gap-2">
            <%= if @current_scope do %>
              <li class="hidden pr-1 text-sm font-medium text-muted-foreground sm:block">
                {@current_scope.user.name}
              </li>
              <li>
                <.button navigate={~p"/users/settings"} variant="ghost" size="sm">
                  Minha conta
                </.button>
              </li>
              <li>
                <.button href={~p"/users/log-out"} method="delete" variant="ghost" size="sm">
                  Sair
                </.button>
              </li>
            <% else %>
              <li>
                <.button navigate={~p"/users/log-in"} variant="ghost" size="sm">
                  Entrar
                </.button>
              </li>
              <li>
                <.button navigate={~p"/users/register"} size="sm">
                  Criar conta
                </.button>
              </li>
            <% end %>
            <li class="pl-1">
              <.theme_toggle />
            </li>
          </ul>
        </nav>
      </div>
    </header>

    <main class="px-3 py-10 sm:px-4 sm:py-14 lg:px-6">
      <div class="mx-auto w-full max-w-7xl space-y-6">
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
  Renders the application brand consistently across screens.
  """
  attr :class, :any, default: nil

  def brand(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-2", @class]}>
      <span
        aria-hidden="true"
        class="flex size-6 items-center justify-center rounded-md bg-primary text-xs text-primary-foreground"
      >
        ⚡
      </span>
      <span>LiveQuiz</span>
    </span>
    """
  end

  @doc """
  Reminds the user to confirm their e-mail address.

  The reminder never blocks navigation: confirming is encouraged, not required
  (see AD-03 of the phase 1 epic).
  """
  attr :current_scope, :map, default: nil

  def unconfirmed_email_notice(%{current_scope: %{user: %{confirmed_at: nil}}} = assigns) do
    ~H"""
    <div
      class="flex items-start gap-3 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm"
      role="status"
    >
      <.icon name="hero-envelope" class="mt-0.5 size-5 shrink-0 text-warning" />
      <span>
        Confirme seu e-mail para manter sua conta segura. Enviamos um link para <strong class="font-medium">{@current_scope.user.email}</strong>.
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
        auto_hide={false}
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
        auto_hide={false}
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
    <div class="relative flex w-fit flex-row items-center rounded-full border border-border bg-muted p-0.5">
      <%!--
        The thumb is positioned from the attributes the bootstrap script in
        root.html.heex stamps on <html>, not from LiveView state: the choice has
        to survive a full page load, and a reload would otherwise paint the thumb
        under the wrong icon until the socket connects.
      --%>
      <div class="absolute h-[calc(100%-0.25rem)] w-1/3 rounded-full bg-background shadow-sm transition-[left] left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-[calc(2/3*100%)] [[data-theme-source=system]_&]:!left-0" />

      <button
        class="relative z-10 flex w-1/3 cursor-pointer justify-center rounded-full p-1.5 text-muted-foreground transition-colors hover:text-foreground focus-visible:ring-[3px] focus-visible:ring-ring/50 focus-visible:outline-hidden"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Usar o tema do sistema"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        class="relative z-10 flex w-1/3 cursor-pointer justify-center rounded-full p-1.5 text-muted-foreground transition-colors hover:text-foreground focus-visible:ring-[3px] focus-visible:ring-ring/50 focus-visible:outline-hidden"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Usar o tema claro"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        class="relative z-10 flex w-1/3 cursor-pointer justify-center rounded-full p-1.5 text-muted-foreground transition-colors hover:text-foreground focus-visible:ring-[3px] focus-visible:ring-ring/50 focus-visible:outline-hidden"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Usar o tema escuro"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
