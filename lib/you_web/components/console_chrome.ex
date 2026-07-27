defmodule YouWeb.Components.ConsoleChrome do
  @moduledoc """
  Operator-console chrome shared by the console shell and the per-app pages:
  the sidebar/topbar frame, the table wrapper, and the small pieces both use.

  Section views stay private to the LiveView that renders them; only what more
  than one LiveView needs lives here.
  """
  use Phoenix.Component

  import YouWeb.MynauiIcons, only: [icon: 1]
  import YouWeb.Components.SiteChrome, only: [wordmark: 1]

  use YouWeb, :verified_routes

  @nav [
    %{id: "overview", label: "Overview", icon: "lucide-layout-dashboard"},
    %{id: "users", label: "Users", icon: "lucide-users"},
    %{id: "apps", label: "Apps", icon: "lucide-boxes"},
    %{id: "audit", label: "Audit Log", icon: "lucide-scroll-text"},
    %{id: "webhooks", label: "Webhooks", icon: "lucide-webhook"},
    %{id: "settings", label: "Settings", icon: "lucide-settings"}
  ]

  @doc "The console sidebar entries, shared by every console LiveView."
  def nav, do: @nav

  @doc """
  The console frame: sidebar navigation, topbar, and a scrolling main area.

  `active` marks the highlighted nav entry, which is a nav id on the console
  itself and stays `"apps"` while a per-app page is open.
  """
  attr :nav, :list, required: true
  attr :active, :string, required: true
  attr :title, :string, required: true
  attr :node_name, :any, required: true
  slot :inner_block, required: true

  def console_shell(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-background text-foreground">
      <aside class="flex w-56 shrink-0 flex-col border-r border-sidebar-border bg-sidebar">
        <div class="flex h-12 items-center gap-2 border-b border-sidebar-border px-4">
          <.wordmark size="sm" />
        </div>

        <nav class="flex-1 space-y-0.5 px-2 pt-2">
          <.link
            :for={n <- @nav}
            navigate={~p"/console?view=#{n.id}"}
            class={[
              "flex h-8 w-full items-center gap-2.5 rounded-md px-2.5 text-sm transition-colors",
              if(@active == n.id,
                do: "bg-sidebar-accent text-sidebar-accent-foreground",
                else: "text-sidebar-foreground hover:bg-sidebar-muted hover:text-foreground"
              )
            ]}
          >
            <span class={[n.icon, "size-4 block shrink-0"]} /> {n.label}
          </.link>
        </nav>

        <div class="space-y-1 border-t border-sidebar-border px-2 py-2">
          <.link
            navigate={~p"/users/settings"}
            class="flex h-8 items-center gap-2.5 rounded-md px-2.5 text-sm text-sidebar-foreground transition-colors hover:bg-sidebar-muted hover:text-foreground"
          >
            <span class="lucide-user size-4 block shrink-0" /> My account
          </.link>
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="flex h-8 items-center gap-2.5 rounded-md px-2.5 text-sm text-sidebar-foreground transition-colors hover:bg-sidebar-muted hover:text-foreground"
          >
            <span class="lucide-log-out size-4 block shrink-0" /> Sign out
          </.link>
        </div>
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="flex h-12 shrink-0 items-center gap-3 border-b border-border px-4">
          <div class="text-sm font-medium">{@title}</div>
          <div class="ml-auto flex items-center gap-3">
            <span class="hidden items-center gap-1.5 font-mono text-xs text-muted-foreground sm:flex">
              <span class="h-1.5 w-1.5 animate-pulse-live rounded-full bg-signal-live" />
              connected · {@node_name}
            </span>
            <.theme_toggle id="console-theme" />
          </div>
        </header>

        <main class="flex-1 overflow-y-auto p-6">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  @doc """
  Bordered table with a mono header row and an empty state that spans every
  column. A trailing `""` column header right-aligns, for action cells.
  """
  attr :cols, :list, required: true
  attr :empty, :boolean, default: false
  slot :inner_block, required: true

  def data_table(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-lg border border-border">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b border-border bg-muted/40 text-left font-mono text-xs uppercase tracking-wide text-muted-foreground">
            <th
              :for={{c, i} <- Enum.with_index(@cols)}
              class={["px-3 py-2 font-medium", i > 0 && c == "" && "text-right"]}
            >
              {c}
            </th>
          </tr>
        </thead>
        <tbody>
          {render_slot(@inner_block)}
          <tr :if={@empty}>
            <td colspan={length(@cols)} class="px-3 py-8 text-center text-sm text-muted-foreground">
              Nothing here yet.
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc "Definition row: muted label left, mono value right."
  attr :k, :string, required: true
  attr :v, :string, required: true

  def kv(assigns) do
    ~H"""
    <div class="flex justify-between gap-4 border-b border-border/60 pb-1.5 last:border-0">
      <dt class="text-muted-foreground">{@k}</dt>
      <dd class="font-mono text-right break-all text-primary">{@v}</dd>
    </div>
    """
  end

  @doc "Light/dark switch driven by the `ThemeToggle` hook."
  attr :id, :string, required: true

  def theme_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      phx-hook="ThemeToggle"
      aria-label="Toggle theme"
      class="grid size-8 place-items-center rounded-md border border-border hover:bg-muted/50"
    >
      <.icon name="moon" class="size-4 text-brand-azure block dark:hidden" />
      <.icon name="sun" class="size-4 text-signal-warn hidden dark:block" />
    </button>
    """
  end

  @doc """
  Tab strip that patches `?tab=`. Each tab is `{id, label}`.
  """
  attr :tabs, :list, required: true
  attr :active, :string, required: true
  attr :path, :string, required: true

  def tab_strip(assigns) do
    ~H"""
    <div class="flex gap-1 border-b border-border" role="tablist">
      <.link
        :for={{id, label} <- @tabs}
        patch={"#{@path}?tab=#{id}"}
        role="tab"
        aria-selected={to_string(@active == id)}
        class={[
          "-mb-px border-b-2 px-3 py-2 text-sm transition-colors",
          if(@active == id,
            do: "border-primary text-foreground",
            else: "border-transparent text-muted-foreground hover:text-foreground"
          )
        ]}
      >
        {label}
      </.link>
    </div>
    """
  end

  @doc "Section card with a title and free-form body."
  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-border bg-card p-5">
      <div class="mb-1 text-sm font-medium">{@title}</div>
      <p :if={@description} class="text-xs text-muted-foreground">{@description}</p>
      <div class="mt-4">{render_slot(@inner_block)}</div>
    </div>
    """
  end
end
