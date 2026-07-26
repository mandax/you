defmodule YouWeb.LandingLive do
  @moduledoc """
  Public landing page.
  """
  use YouWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:page_title, "Self-hosted identity, standard OIDC")
    |> then(&{:ok, &1})
  end
end
