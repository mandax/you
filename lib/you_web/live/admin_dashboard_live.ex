defmodule YouWeb.AdminDashboardLive do
  use YouWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:user_count, length(You.Admin.list_users()))
     |> assign(:app_count, length(You.Admin.list_apps()))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab="dashboard"
      user_count={@user_count}
      app_count={@app_count}
    >
      <:side_panel>
        <div class="text-[11px] font-medium text-muted-foreground uppercase tracking-widest">
          Overview
        </div>
        <p class="text-xs text-muted-foreground leading-relaxed">
          Your You instance manages users and apps.
        </p>
        <div class="mt-2 border-t border-border pt-3">
          <.button variant="outline" size="sm" navigate={~p"/console/apps"} class="w-full justify-center">
            + Create App
          </.button>
        </div>
      </:side_panel>

      <div class="space-y-6">
        <h2 class="text-xl font-medium tracking-tight">Dashboard</h2>
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <.card class="p-5">
            <div class="text-xs text-muted-foreground">Users</div>
            <div class="text-3xl font-semibold mt-1">{@user_count}</div>
          </.card>
          <.card class="p-5">
            <div class="text-xs text-muted-foreground">Apps</div>
            <div class="text-3xl font-semibold mt-1">{@app_count}</div>
          </.card>
          <.card class="p-5">
            <div class="text-xs text-muted-foreground">Active Sessions</div>
            <div class="text-3xl font-semibold mt-1">—</div>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
