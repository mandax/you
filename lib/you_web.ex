defmodule YouWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use YouWeb, :controller
      use YouWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images videos favicon.ico)

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

      use Gettext, backend: YouWeb.Gettext

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
      use Gettext, backend: YouWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components. `button/1` is superseded by
      # YouWeb.Components.Base.Button (the form-aware `input/1` here is kept;
      # the Base layer's input primitive is the unstyled `base_input/1`).
      import YouWeb.CoreComponents
      # MynaUI icons
      import YouWeb.MynauiIcons, only: [icon: 1]

      # Base UI–inspired primitives.
      import YouWeb.Components.Base.Badge
      import YouWeb.Components.Base.Button
      import YouWeb.Components.Base.CopyButton
      import YouWeb.Components.Base.Dialog
      import YouWeb.Components.Base.DropdownMenu
      import YouWeb.Components.Base.Input
      import YouWeb.Components.Base.Select
      import YouWeb.Components.Base.Sheet
      import YouWeb.Components.Base.Switch

      # Shared presentational pieces (eyebrow, status dot, sparkline, …)
      import YouWeb.Components.Bits

      # Public-site chrome (wordmark, nav, footer) shared by landing and docs
      import YouWeb.Components.SiteChrome

      # Login-page chrome, shared by the real login and the console preview
      import YouWeb.Components.LoginChrome

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias YouWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: YouWeb.Endpoint,
        router: YouWeb.Router,
        statics: YouWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
