defmodule YouWeb.AdminAppsLive do
  use YouWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :apps, [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab="apps"
      user_count={0}
      app_count={0}
    >
      <:side_panel>
        <div class="text-[11px] font-medium text-muted-foreground uppercase tracking-widest">Apps</div>
        <a href="#" class="text-sm text-muted-foreground hover:text-foreground transition-colors">
          All Apps
        </a>
        <a href="#" class="text-sm text-muted-foreground hover:text-foreground transition-colors">
          Active
        </a>
        <a href="#" class="text-sm text-muted-foreground hover:text-foreground transition-colors">
          Inactive
        </a>
        <div class="mt-auto pt-4 border-t border-border">
          <.button variant="outline" size="sm" class="w-full justify-center">+ New App</.button>
        </div>
      </:side_panel>

      <div class="space-y-6">
        <h2 class="text-xl font-medium tracking-tight">Apps</h2>
        <p class="text-sm text-muted-foreground">No apps configured yet.</p>
      </div>
    </Layouts.app>
    """
  end
end
