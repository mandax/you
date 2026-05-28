defmodule YouWeb.AdminUsersLive do
  use YouWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :users, [])}
  end

  @impl true
  def render(assigns) do
    ~H"<h1>Users</h1>"
  end
end
