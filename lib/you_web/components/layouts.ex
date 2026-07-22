defmodule YouWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use YouWeb, :html

  embed_templates "layouts/*"

  # ──────────────────────────────────────────────
  # Public layout — landing, docs, pricing, etc.
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
            <.link navigate={~p"/"} class="flex items-center gap-2 font-medium text-sm tracking-tight">
              <div class="size-6 rounded-md bg-primary text-primary-foreground flex items-center justify-center">
                <span class="text-[10px] font-bold">Y</span>
              </div>
              You
            </.link>
          </div>
          <nav class="flex items-center gap-6 text-sm">
            <span class="hidden sm:flex items-center gap-6">
              <.link navigate="/" class="text-muted-foreground hover:text-foreground transition-colors">
                Home
              </.link>
              <.link
                navigate="/docs"
                class="text-muted-foreground hover:text-foreground transition-colors"
              >
                Docs
              </.link>
              <.link
                navigate="/#pricing"
                class="text-muted-foreground hover:text-foreground transition-colors"
              >
                Pricing
              </.link>
            </span>
            <div class="flex items-center gap-3 ml-2">
              <.theme_toggle id="public-theme" />
              <%= if @current_scope do %>
                <.button size="sm" navigate={~p"/console"}>Console</.button>
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
        You — Identity &amp; Access Management
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  # ──────────────────────────────────────────────
  # App layout — authenticated area (tabs + side panel)
  # ──────────────────────────────────────────────
  attr :flash, :map, default: %{}, doc: "flash messages"
  attr :current_scope, :map, default: nil, doc: "the current user scope"

  attr :active_tab, :string,
    required: true,
    doc: "one of: dashboard, users, apps, orgs, audit, settings"

  attr :user_count, :integer, default: nil
  attr :app_count, :integer, default: nil
  slot :side_panel, required: true, doc: "contextual sidebar content for the active tab"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col">
      <!-- Slim top bar -->
      <header class="h-12 shrink-0 border-b border-border bg-background/80 backdrop-blur-md flex items-center">
        <!-- Logo -->
        <div class="w-56 shrink-0 px-5 border-r border-border h-full flex items-center">
          <.link
            navigate={~p"/console"}
            class="flex items-center gap-2 font-medium text-sm tracking-tight"
          >
            <div class="size-6 rounded-md bg-primary text-primary-foreground flex items-center justify-center">
              <span class="text-[10px] font-bold">Y</span>
            </div>
            You
          </.link>
        </div>

    <!-- Tabs -->
        <nav class="flex items-center h-full px-4 gap-0.5">
          <.tab_link active={@active_tab == "dashboard"} navigate={~p"/console"}>
            Dashboard
          </.tab_link>
          <.tab_link active={@active_tab == "users"} navigate={~p"/console/users"}>
            Users
            <span
              :if={@user_count}
              class="text-[10px] ml-1 px-1.5 py-0.5 rounded-full bg-muted text-muted-foreground"
            >
              {@user_count}
            </span>
          </.tab_link>
          <.tab_link active={@active_tab == "apps"} navigate={~p"/console/apps"}>
            Apps
            <span
              :if={@app_count}
              class="text-[10px] ml-1 px-1.5 py-0.5 rounded-full bg-muted text-muted-foreground"
            >
              {@app_count}
            </span>
          </.tab_link>
          <.tab_link active={@active_tab == "orgs"} navigate={~p"/console/orgs"}>
            Orgs
          </.tab_link>
          <.tab_link active={@active_tab == "audit"} navigate={~p"/console/audit"}>
            Audit Log
          </.tab_link>
          <.tab_link active={@active_tab == "settings"} navigate={~p"/console/settings"}>
            Settings
          </.tab_link>
        </nav>

    <!-- Right side -->
        <div class="flex items-center gap-2 px-5 ml-auto">
          <.theme_toggle id="app-theme" />
          <.user_dropdown current_scope={@current_scope} />
        </div>
      </header>

    <!-- Body: side panel + content -->
      <div class="flex flex-1 min-h-0">
        <!-- Contextual side panel -->
        <aside class="w-56 shrink-0 border-r border-border bg-sidebar p-4 flex flex-col gap-3 text-sm">
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

  attr :active, :boolean, default: false
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "inline-flex items-center px-3 h-8 rounded-md text-sm font-medium transition-all duration-150",
        if(@active,
          do: "bg-muted text-foreground",
          else: "text-muted-foreground hover:text-foreground hover:bg-muted/50"
        )
      ]}
    >
      {render_slot(@inner_block)}
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
      <div :if={@current_scope} class="px-2 py-1.5 text-xs text-muted-foreground border-b border-border truncate">
        {@current_scope.user.email}
      </div>
      <.menu_item :if={@current_scope} navigate={~p"/users/settings"}>Settings</.menu_item>
      <.menu_item :if={@current_scope} href={~p"/users/log-out"} method="delete" class="text-destructive">
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
      class="size-8 rounded-lg border border-border flex items-center justify-center hover:bg-muted/50 transition-colors"
    >
      <.icon name="moon" class="size-4 text-azure-brand block dark:hidden" />
      <.icon name="sun" class="size-4 text-signal-warn hidden dark:block" />
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
