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
      <header class="sticky top-0 z-40 border-b border-base-300/50 bg-base-100/80 backdrop-blur-md">
        <div class="mx-auto max-w-6xl px-6 h-14 flex items-center justify-between">
          <div class="flex items-center gap-2">
            <.link navigate={~p"/"} class="flex items-center gap-2 font-medium text-sm tracking-tight">
              <div class="size-6 rounded-md bg-neutral text-neutral-content flex items-center justify-center">
                <span class="text-[10px] font-bold">Y</span>
              </div>
              You
            </.link>
          </div>
          <nav class="flex items-center gap-6 text-sm">
            <span class="hidden sm:flex items-center gap-6">
              <.link
                navigate="/"
                class="text-base-content/60 hover:text-base-content transition-colors"
              >
                Home
              </.link>
              <.link
                navigate="/docs"
                class="text-base-content/60 hover:text-base-content transition-colors"
              >
                Docs
              </.link>
              <.link
                navigate="/pricing"
                class="text-base-content/60 hover:text-base-content transition-colors"
              >
                Pricing
              </.link>
            </span>
            <div class="flex items-center gap-3 ml-2">
              <.theme_toggle id="public-theme" />
              <%= if @current_scope do %>
                <.link
                  navigate={~p"/admin"}
                  class="btn btn-primary btn-sm"
                >
                  Dashboard
                </.link>
              <% else %>
                <.link
                  navigate={~p"/users/log-in"}
                  class="text-sm text-base-content/60 hover:text-base-content transition-colors"
                >
                  Log in
                </.link>
                <.link
                  navigate={~p"/users/register"}
                  class="btn btn-primary btn-sm"
                >
                  Sign up
                </.link>
              <% end %>
            </div>
          </nav>
        </div>
      </header>

      <main class="flex-1">
        {render_slot(@inner_block)}
      </main>

      <footer class="border-t border-base-300 py-8 text-center text-xs text-base-content/40">
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
    doc: "one of: dashboard, users, apps, audit, settings"

  attr :user_count, :integer, default: nil
  attr :app_count, :integer, default: nil
  slot :side_panel, required: true, doc: "contextual sidebar content for the active tab"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col">
      <!-- Slim top bar -->
      <header class="h-12 shrink-0 border-b border-base-300 bg-base-100/80 backdrop-blur-md flex items-center">
        <!-- Logo -->
        <div class="w-56 shrink-0 px-5 border-r border-base-300 h-full flex items-center">
          <.link
            navigate={~p"/admin"}
            class="flex items-center gap-2 font-medium text-sm tracking-tight"
          >
            <div class="size-6 rounded-md bg-neutral text-neutral-content flex items-center justify-center">
              <span class="text-[10px] font-bold">Y</span>
            </div>
            You
          </.link>
        </div>
        
    <!-- Tabs -->
        <nav class="flex items-center h-full px-4 gap-0.5">
          <.tab_link active={@active_tab == "dashboard"} navigate={~p"/admin"}>
            Dashboard
          </.tab_link>
          <.tab_link active={@active_tab == "users"} navigate={~p"/admin/users"}>
            Users
            <span
              :if={@user_count}
              class="text-[10px] ml-1 px-1.5 py-0.5 rounded-full bg-base-300 text-base-content/60"
            >
              {@user_count}
            </span>
          </.tab_link>
          <.tab_link active={@active_tab == "apps"} navigate={~p"/admin/apps"}>
            Apps
            <span
              :if={@app_count}
              class="text-[10px] ml-1 px-1.5 py-0.5 rounded-full bg-base-300 text-base-content/60"
            >
              {@app_count}
            </span>
          </.tab_link>
          <.tab_link active={@active_tab == "audit"} navigate={~p"/admin/audit"}>
            Audit Log
          </.tab_link>
          <.tab_link active={@active_tab == "settings"} navigate={~p"/admin/settings"}>
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
        <aside class="w-56 shrink-0 border-r border-base-300 bg-base-200/50 p-4 flex flex-col gap-3 text-sm">
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
          do: "bg-base-300 text-base-content",
          else: "text-base-content/50 hover:text-base-content hover:bg-base-300/50"
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
    <div class="dropdown dropdown-end">
      <button
        tabindex="0"
        role="button"
        class="size-8 rounded-full bg-base-300 flex items-center justify-center text-xs font-medium hover:bg-base-300/80 transition-colors"
      >
        <%= if @current_scope do %>
          {String.at(@current_scope.user.email, 0) |> String.upcase()}
        <% else %>
          ?
        <% end %>
      </button>
      <ul
        tabindex="0"
        class="dropdown-content menu menu-sm rounded-lg bg-base-100 border border-base-300 shadow-sm w-44 mt-1 z-50"
      >
        <%= if @current_scope do %>
          <li class="px-3 py-2 text-xs text-base-content/50 border-b border-base-300 truncate">
            {@current_scope.user.email}
          </li>
          <li><.link href={~p"/users/settings"} class="px-3 py-2">Settings</.link></li>
          <li>
            <.link href={~p"/users/log-out"} method="delete" class="px-3 py-2 text-error">
              Log out
            </.link>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true

  defp theme_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      phx-hook="ThemeToggle"
      aria-label="Toggle theme"
      class="size-8 rounded-lg border border-base-300 flex items-center justify-center hover:bg-base-300/50 transition-colors"
    >
      <.icon name="moon" class="size-4 text-indigo-400 block dark:hidden" />
      <.icon name="sun" class="size-4 text-amber-500 hidden dark:block" />
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
