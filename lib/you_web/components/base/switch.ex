defmodule YouWeb.Components.Base.Switch do
  @moduledoc """
  On/off switch.

  A `<button role="switch">` rather than a styled checkbox: the state is applied
  immediately by the server (there is no form to submit), and `aria-checked`
  is what assistive tech reads for that.

  Purely presentational beyond the role. Click handling is the caller's, passed
  straight through as `phx-click` / `phx-value-*`.

  ## Examples

      <.switch checked={@endpoint.enabled} phx-click="toggle_webhook" phx-value-id={@endpoint.id} />
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  attr :checked, :boolean, default: false
  attr :label, :string, default: nil, doc: "text shown next to the switch"
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def switch(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2">
      <button
        type="button"
        role="switch"
        aria-checked={to_string(@checked)}
        aria-label={@label}
        disabled={@disabled}
        class={
          cx([
            "relative inline-flex h-4 w-7 shrink-0 items-center rounded-full transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-50",
            if(@checked, do: "bg-signal-ok", else: "bg-input"),
            @class
          ])
        }
        {@rest}
      >
        <span class={
          cx([
            "pointer-events-none block size-3 rounded-full bg-background shadow transition-transform",
            if(@checked, do: "translate-x-3.5", else: "translate-x-0.5")
          ])
        } />
      </button>
      <span :if={@label} class="font-mono text-[11px] text-muted-foreground">{@label}</span>
    </span>
    """
  end
end
