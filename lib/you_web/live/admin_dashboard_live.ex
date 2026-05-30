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
        <div class="text-[11px] font-medium text-base-content/40 uppercase tracking-widest">
          Overview
        </div>
        <p class="text-xs text-base-content/50 leading-relaxed">
          Your You instance manages users and apps.
        </p>
        <div class="mt-2 border-t border-base-300 pt-3">
          <.link navigate={~p"/admin/apps"} class="btn btn-soft btn-sm w-full justify-center">
            + Create App
          </.link>
        </div>
      </:side_panel>

      <div class="space-y-6">
        <h2 class="text-xl font-medium tracking-tight">Dashboard</h2>
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <div class="rounded-xl border border-base-300 p-5">
            <div class="text-xs text-base-content/40">Users</div>
            <div class="text-3xl font-semibold mt-1">{@user_count}</div>
          </div>
          <div class="rounded-xl border border-base-300 p-5">
            <div class="text-xs text-base-content/40">Apps</div>
            <div class="text-3xl font-semibold mt-1">{@app_count}</div>
          </div>
          <div class="rounded-xl border border-base-300 p-5">
            <div class="text-xs text-base-content/40">Active Sessions</div>
            <div class="text-3xl font-semibold mt-1">—</div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
