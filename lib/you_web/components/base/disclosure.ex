defmodule YouWeb.Components.Base.Disclosure do
  @moduledoc """
  Expandable section built on native `<details>`.

  No hook and no JS: the element already handles toggling, keyboard access and
  the open/closed state, and it stays usable if scripting fails. The arrow is
  rotated with `group-open:`, which reads the parent's `open` attribute.
  """
  use Phoenix.Component

  @doc """
  A collapsible panel.

  `open` only sets the initial state — after that the element owns it, so a
  re-render will not snap a section the reader opened back shut.
  """
  attr :id, :string, required: true
  attr :summary, :string, required: true
  attr :open, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def disclosure(assigns) do
    ~H"""
    <details id={@id} open={@open} class={["group rounded-md border border-border", @class]}>
      <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-2 text-sm text-muted-foreground transition-colors hover:text-foreground [&::-webkit-details-marker]:hidden">
        <span class="lucide-chevron-right size-4 block shrink-0 transition-transform group-open:rotate-90" />
        {@summary}
      </summary>
      <div class="border-t border-border px-3 py-3">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end
end
