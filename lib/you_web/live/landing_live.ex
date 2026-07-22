defmodule YouWeb.LandingLive do
  @moduledoc """
  Public landing page.

  The two bits of interactivity — the hero terminal's tabs and the FAQ
  accordion — run through LiveView assigns rather than a colocated hook:
  both are already connected, neither is latency-sensitive the way a menu
  or a palette is, and keeping them server-side means no JS to maintain for
  a marketing page.

  Copy-to-clipboard is the exception and uses `<.copy_button>`, since the
  clipboard API only exists on the client.
  """
  use YouWeb, :live_view

  alias YouWeb.LandingContent

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:page_title, "Self-hosted identity for the BEAM")
    |> assign(:tab, "redirect")
    |> assign(:faq_open, 0)
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) when tab in ~w(redirect exchange) do
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_event("toggle_faq", %{"index" => index}, socket) do
    index = String.to_integer(index)

    {:noreply,
     assign(socket, :faq_open, if(socket.assigns.faq_open == index, do: nil, else: index))}
  end

  @doc """
  Hero terminal. Tabs swap the sample; the copy button lifts whichever is active.
  """
  attr :tab, :string, required: true

  def terminal_pane(assigns) do
    assigns =
      assign(assigns, tabs: LandingContent.terminal_tabs(), active: active_tab(assigns.tab))

    ~H"""
    <div class="overflow-hidden rounded-xl border border-border bg-card shadow-2xl shadow-black/30">
      <div class="flex items-center justify-between border-b border-border bg-muted/40 px-4 py-2.5">
        <div class="flex items-center gap-2">
          <span class="h-2.5 w-2.5 rounded-full bg-signal-down/70" />
          <span class="h-2.5 w-2.5 rounded-full bg-signal-warn/70" />
          <span class="h-2.5 w-2.5 rounded-full bg-signal-ok/70" />
          <span class="ml-2 font-mono text-xs text-muted-foreground">{@active.file}</span>
        </div>
        <span class="inline-flex items-center gap-1.5 rounded-full border border-azure-brand/30 bg-azure-brand/10 px-2 py-0.5 font-mono text-[11px] text-azure-brand">
          <span class="h-1.5 w-1.5 animate-pulse-live rounded-full bg-signal-live" /> self-hosted
        </span>
      </div>

      <div class="flex items-center gap-1 border-b border-border px-2 py-1.5">
        <button
          :for={tab <- @tabs}
          type="button"
          phx-click="select_tab"
          phx-value-tab={tab.id}
          aria-pressed={to_string(@tab == tab.id)}
          class={[
            "rounded px-2.5 py-1 font-mono text-xs transition-colors",
            if(@tab == tab.id,
              do: "bg-muted text-foreground",
              else: "text-muted-foreground hover:text-foreground"
            )
          ]}
        >
          {tab.label}
        </button>
        <div class="ml-auto">
          <.copy_button id="copy-terminal" value={@active.code} />
        </div>
      </div>

      <div id="terminal-body" phx-hook=".TerminalHeight" class="overflow-hidden">
        <pre class="overflow-x-auto p-4 font-mono text-[12.5px] leading-relaxed text-foreground/90"><code>{@active.code}</code></pre>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TerminalHeight">
      export default {
        // The two samples have different heights; without this the pane snaps
        // between them. Capture the outgoing height before LiveView patches the
        // <pre>, then transition from it to the new natural height.
        reduced() {
          return window.matchMedia("(prefers-reduced-motion: reduce)").matches
        },

        beforeUpdate() {
          this.prev = this.el.offsetHeight
        },

        updated() {
          if (this.reduced() || this.prev == null) return
          const target = this.el.scrollHeight
          if (target === this.prev) return

          this.el.style.height = this.prev + "px"
          void this.el.offsetHeight // force reflow so the start height sticks
          this.el.style.transition = "height 240ms ease"
          this.el.style.height = target + "px"

          const done = () => {
            this.el.style.height = ""
            this.el.style.transition = ""
            this.el.removeEventListener("transitionend", done)
            clearTimeout(this.fallback)
          }
          this.el.addEventListener("transitionend", done)
          // transitionend can be missed (tab-away, interrupted swap); clean up anyway.
          this.fallback = setTimeout(done, 400)
        },

        destroyed() {
          clearTimeout(this.fallback)
        }
      }
    </script>
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

  defp terminal_tabs, do: LandingContent.terminal_tabs()
  defp active_tab(tab), do: Enum.find(terminal_tabs(), &(&1.id == tab))
end
