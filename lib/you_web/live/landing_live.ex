defmodule YouWeb.LandingLive do
  @moduledoc """
  Public landing page.

  The FAQ accordion runs through LiveView assigns rather than a hook: it's
  already connected, not latency-sensitive, and keeping it server-side means
  no JS to maintain for a marketing page.
  """
  use YouWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:page_title, "Self-hosted identity, standard OIDC")
    |> assign(:faq_open, 0)
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_event("toggle_faq", %{"index" => index}, socket) do
    index = String.to_integer(index)

    {:noreply,
     assign(socket, :faq_open, if(socket.assigns.faq_open == index, do: nil, else: index))}
  end
end
