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

  @doc """
  Syntax-highlighted code block (server-side, via Makeup).
  """
  attr :code, :string, required: true

  def highlighted_code(assigns) do
    ~H"""
    <pre class="overflow-x-auto p-4 font-mono text-[13px] leading-relaxed makeup"><code>{Phoenix.HTML.raw(Makeup.highlight(@code))}</code></pre>
    """
  end

  @doc """
  Comparison table cell — check, dash, or cross.
  """
  attr :value, :atom, required: true, values: [:yes, :no, :partial]

  def comparison_cell(assigns) do
    ~H"""
    <span
      :if={@value == :yes}
      class="lucide-check mx-auto size-4 block text-signal-ok"
      aria-label="yes"
      role="img"
    />
    <span
      :if={@value == :partial}
      class="lucide-minus mx-auto size-4 block text-signal-warn"
      aria-label="partial"
      role="img"
    />
    <span
      :if={@value == :no}
      class="lucide-x mx-auto size-4 block text-muted-foreground/50"
      aria-label="no"
      role="img"
    />
    """
  end
end
