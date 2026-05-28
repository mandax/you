defmodule YouWeb.AdminSettingsLive do
  use YouWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :settings, %{})}
  end

  @impl true
  def render(assigns) do
    ~H"<h1>Settings</h1>"
  end
end
