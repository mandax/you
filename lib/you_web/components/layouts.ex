defmodule YouWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use YouWeb, :html

  embed_templates "layouts/*"

  @doc """
  Frame for the authentication flow: login, registration, password reset,
  second factor, consent.

  `bare` renders an app's page — the form centred and nothing else, since the
  page belongs to that app rather than to You. Otherwise it is You's own page,
  inside the public chrome.
  """
  attr :flash, :map, default: %{}
  attr :current_scope, :map, default: nil
  attr :bare, :boolean, default: false
  attr :brand_style, :string, default: nil
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <%= if @bare do %>
      <div
        class={[
          "flex min-h-screen items-center justify-center px-5 py-16",
          @brand_style && "app-branded"
        ]}
        style={@brand_style}
      >
        <div class="w-full max-w-sm animate-rise-in space-y-6">
          {render_slot(@inner_block)}
        </div>
      </div>

      <.flash_group flash={@flash} />
    <% else %>
      <.public flash={@flash} current_scope={@current_scope}>
        <div class="mx-auto max-w-sm pt-24 pb-32 space-y-6">
          {render_slot(@inner_block)}
        </div>
      </.public>
    <% end %>
    """
  end

  @doc """
  Header for an authentication page: the app's logo and name when the flow
  belongs to one, You's wordmark when it does not.
  """
  attr :bare, :boolean, default: false
  attr :app_name, :string, default: nil
  attr :app_logo_url, :string, default: nil

  def auth_mark(assigns) do
    ~H"""
    <img
      :if={@bare && @app_logo_url}
      src={@app_logo_url}
      alt={@app_name}
      class="mx-auto mb-4 h-12 w-auto max-w-[200px] object-contain"
    />
    <span
      :if={@bare && !@app_logo_url}
      class="lucide-lock mx-auto mb-4 block size-8 text-muted-foreground"
    />
    <.wordmark :if={!@bare} size="lg" class="justify-center mb-4" />
    """
  end

  # ──────────────────────────────────────────────
  # Public layout: landing, docs, pricing, etc.
  # ──────────────────────────────────────────────
  attr :flash, :map, default: %{}, doc: "flash messages"
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def public(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col">
      <header class="sticky top-0 z-40 border-b border-border bg-background/80 backdrop-blur-md">
        <div class="mx-auto max-w-6xl px-6 h-14 flex items-center justify-between">
          <div class="flex items-center gap-2">
            <.wordmark />
          </div>
          <nav class="flex items-center gap-6 text-sm">
            <span class="hidden sm:flex items-center gap-6">
              <.link
                navigate="/"
                class="text-muted-foreground hover:text-foreground transition-colors"
              >
                Home
              </.link>
              <%!-- There is no /docs route: the docs live in the repo, which is
                    where the landing footer already sends people. --%>
              <.link
                href="https://github.com/mandax/you/tree/main/docs"
                class="text-muted-foreground hover:text-foreground transition-colors"
              >
                Docs
              </.link>
              <.link
                navigate="/#get-started"
                class="text-muted-foreground hover:text-foreground transition-colors"
              >
                Get started
              </.link>
            </span>
            <div class="flex items-center gap-3 ml-2">
              <.theme_toggle id="public-theme" />
              <%= if @current_scope do %>
                <.button size="sm" navigate={YouWeb.UserAuth.account_path()}>
                  {YouWeb.UserAuth.account_label()}
                </.button>
              <% else %>
                <.link
                  navigate={~p"/users/log-in"}
                  class="text-sm text-muted-foreground hover:text-foreground transition-colors"
                >
                  Log in
                </.link>
                <.button size="sm" navigate={~p"/users/register"}>Sign up</.button>
              <% end %>
            </div>
          </nav>
        </div>
      </header>

      <main class="flex-1">
        {render_slot(@inner_block)}
      </main>

      <footer class="border-t border-border py-8 text-center text-xs text-muted-foreground">
        You · Identity &amp; Access Management
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  # ──────────────────────────────────────────────
  # App layout: authenticated area (tabs + side panel)
  # ──────────────────────────────────────────────
  attr :flash, :map, default: %{}, doc: "flash messages"
  attr :current_scope, :map, default: nil, doc: "the current user scope"

  attr :active_tab, :string, default: nil, doc: "legacy, unused"
  attr :user_count, :integer, default: nil
  attr :app_count, :integer, default: nil
  slot :side_panel, doc: "optional contextual sidebar content"
  slot :inner_block, required: true

  def app(assigns) do
    panel_app = YouWeb.AppBranding.panel_app()

    assigns =
      assigns
      |> assign(:panel_app, panel_app)
      |> assign(:brand_style, YouWeb.AppBranding.app_brand_style(panel_app))

    ~H"""
    <div
      class={["min-h-screen flex flex-col", @brand_style && "app-branded"]}
      style={@brand_style}
    >
      <!-- Slim top bar -->
      <header class="h-12 shrink-0 border-b border-border bg-background/80 backdrop-blur-md flex items-center">
        <!-- Logo -->
        <div class="w-56 shrink-0 px-5 border-r border-border h-full flex items-center">
          <img
            :if={@panel_app && @panel_app.logo_url}
            src={@panel_app.logo_url}
            alt={@panel_app.name}
            class="h-6 w-auto max-w-[140px] object-contain"
          />
          <span
            :if={@panel_app && !@panel_app.logo_url}
            class="truncate text-sm font-semibold tracking-tight"
          >
            {@panel_app.name}
          </span>
          <.wordmark :if={!@panel_app} size="sm" />
        </div>

        <div class="px-4 text-sm font-medium text-muted-foreground">Account</div>
        
    <!-- Right side -->
        <div class="flex items-center gap-2 px-5 ml-auto">
          <.theme_toggle id="app-theme" />
          <.user_dropdown current_scope={@current_scope} />
        </div>
      </header>
      
    <!-- Body: optional side panel + content -->
      <div class="flex flex-1 min-h-0">
        <aside
          :if={@side_panel != []}
          class="w-56 shrink-0 border-r border-border bg-sidebar p-4 flex flex-col gap-3 text-sm"
        >
          {render_slot(@side_panel)}
        </aside>
        
    <!-- Page content -->
        <main class="flex-1 overflow-auto p-6">
          <div class="max-w-4xl animate-fade-in">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  # ──────────────────────────────────────────────
  # Components
  # ──────────────────────────────────────────────

  @doc """
  Shared account-area side nav, used by every signed-in user page (dashboard,
  settings, passkeys) so they cross-link and feel like one section.
  """
  attr :active, :string, default: nil, doc: "one of: dashboard, settings, passkeys"

  def account_nav(assigns) do
    ~H"""
    <div class="text-[11px] font-medium text-muted-foreground uppercase tracking-widest mb-1">
      Account
    </div>
    <.account_link
      :if={!You.Mode.single?()}
      navigate={~p"/users/dashboard"}
      icon="lucide-grid-2x2"
      active={@active == "dashboard"}
    >
      Your apps
    </.account_link>
    <.account_link
      navigate={~p"/users/settings"}
      icon="lucide-settings"
      active={@active == "settings"}
    >
      Settings
    </.account_link>
    <.account_link
      navigate={~p"/users/settings/passkeys"}
      icon="lucide-key-round"
      active={@active == "passkeys"}
    >
      Passkeys
    </.account_link>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp account_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-2.5 rounded-md px-2.5 h-8 text-sm transition-colors",
        if(@active,
          do: "bg-muted text-foreground font-medium",
          else: "text-muted-foreground hover:text-foreground hover:bg-muted/50"
        )
      ]}
    >
      <span class={[@icon, "size-4 block shrink-0"]} /> {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :current_scope, :map, default: nil

  defp user_dropdown(assigns) do
    ~H"""
    <.dropdown_menu id="user-menu" align="end">
      <:trigger>
        <span class="size-8 rounded-full bg-muted flex items-center justify-center text-xs font-medium hover:bg-muted/80 transition-colors">
          <%= if @current_scope do %>
            {String.at(@current_scope.user.email, 0) |> String.upcase()}
          <% else %>
            ?
          <% end %>
        </span>
      </:trigger>
      <div
        :if={@current_scope}
        class="px-2 py-1.5 text-xs text-muted-foreground border-b border-border truncate"
      >
        {@current_scope.user.email}
      </div>
      <%!-- In single mode both of these land on the settings page, so only
            one of them is worth showing. --%>
      <.menu_item :if={@current_scope && !You.Mode.single?()} navigate={~p"/users/dashboard"}>
        Dashboard
      </.menu_item>
      <.menu_item :if={@current_scope} navigate={~p"/users/settings"}>Settings</.menu_item>
      <.menu_item
        :if={@current_scope && @current_scope.user.is_admin}
        navigate={~p"/console"}
        class="text-primary"
      >
        Console
      </.menu_item>
      <.menu_item
        :if={@current_scope}
        href={~p"/users/log-out"}
        method="delete"
        class="text-destructive"
      >
        Log out
      </.menu_item>
    </.dropdown_menu>
    """
  end

  attr :id, :string, required: true

  defp theme_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      phx-hook="ThemeToggle"
      aria-label="Toggle theme"
      class="size-8 rounded-lg border border-border flex items-center justify-center text-muted-foreground hover:bg-muted/50 hover:text-foreground transition-colors"
    >
      <.icon name="moon" class="size-4 block dark:hidden" />
      <.icon name="sun" class="size-4 hidden dark:block" />
    </button>
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
    </div>
    """
  end
end
