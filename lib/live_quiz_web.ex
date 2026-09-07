defmodule LiveQuizWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use LiveQuizWeb, :controller
      use LiveQuizWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  @doc """
  Whether cookies are written with the `secure` flag.

  Every cookie this application writes carries a credential — the session, a
  guest's participation, the fortnight-long remember-me — so all three ask the
  same question, and it is answered in one place.

  On in production. Off wherever the application is served over http, which is
  what development and the suite do: a secure cookie sent over http is one the
  browser never sends back, so switching it on everywhere would not harden
  anything, it would break logging in locally.
  """
  @spec secure_cookies?() :: boolean()
  def secure_cookies?, do: Application.get_env(:live_quiz, :secure_cookies, false)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: LiveQuizWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: LiveQuizWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import LiveQuizWeb.CoreComponents

      # Common modules used in templates
      alias LiveQuizWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: LiveQuizWeb.Endpoint,
        router: LiveQuizWeb.Router,
        statics: LiveQuizWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
