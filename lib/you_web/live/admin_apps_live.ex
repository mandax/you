defmodule YouWeb.AdminAppsLive do
  use YouWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :apps, [])}
  end

  @impl true
  def render(assigns) do
    ~H"<h1>Apps</h1>"
  end
end
