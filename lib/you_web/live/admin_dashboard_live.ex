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
    <h1>Admin Dashboard</h1>
    <div class="stats">
      <div class="stat"><strong>Users:</strong> {@user_count}</div>
      <div class="stat"><strong>Apps:</strong> {@app_count}</div>
    </div>
    """
  end
end
