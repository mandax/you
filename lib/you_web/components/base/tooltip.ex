defmodule YouWeb.Components.Base.Tooltip do
  @moduledoc """
  Hover/focus tooltip.

  Anatomy follows Base UI — a `trigger` slot and the tooltip content as the
  default slot — collapsed into one component because the popup is always
  anchored to its own trigger and never needs to be composed separately.

  Behavior lives in a colocated hook: show on hover and on keyboard focus, hide
  on leave, blur, and Escape. The popup is `aria-hidden` while closed and wired
  to the trigger with `aria-describedby`, so screen readers announce it as a
  description rather than as content the user has to find.

  Opening is intentionally client-side — a tooltip that round-trips to the
  server before appearing feels broken.

  ## Examples

      <.tooltip id="copy-tip">
        <:trigger>
          <button class="lucide-copy" />
        </:trigger>
        Copy to clipboard
      </.tooltip>
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  attr :id, :string, required: true
  attr :side, :string, default: "top", values: ~w(top bottom left right)
  attr :class, :any, default: nil
  attr :rest, :global

  slot :trigger, required: true
  slot :inner_block, required: true

  def tooltip(assigns) do
    ~H"""
    <span id={@id} phx-hook=".Tooltip" class="relative inline-flex" {@rest}>
      <span data-part="trigger" aria-describedby={"#{@id}-popup"} class="inline-flex">
        {render_slot(@trigger)}
      </span>

      <span
        id={"#{@id}-popup"}
        role="tooltip"
        data-part="popup"
        data-side={@side}
        aria-hidden="true"
        class={
          cx([
            "pointer-events-none absolute z-50 w-max max-w-xs overflow-hidden rounded-md border border-border bg-popover px-3 py-1.5 text-sm text-popover-foreground shadow-md",
            "scale-95 opacity-0 transition-[transform,opacity] duration-150",
            "data-[open]:scale-100 data-[open]:opacity-100",
            side_classes(@side),
            @class
          ])
        }
      >
        {render_slot(@inner_block)}
      </span>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Tooltip">
      export default {
        mounted() {
          this.trigger = this.el.querySelector('[data-part="trigger"]')
          this.popup = this.el.querySelector('[data-part="popup"]')

          this.open = () => {
            this.popup.setAttribute("data-open", "")
            this.popup.setAttribute("aria-hidden", "false")
          }
          this.close = () => {
            this.popup.removeAttribute("data-open")
            this.popup.setAttribute("aria-hidden", "true")
          }

          this.onKeydown = (e) => { if (e.key === "Escape") this.close() }

          this.trigger.addEventListener("mouseenter", this.open)
          this.trigger.addEventListener("mouseleave", this.close)
          this.trigger.addEventListener("focusin", this.open)
          this.trigger.addEventListener("focusout", this.close)
          document.addEventListener("keydown", this.onKeydown)
        },

        destroyed() {
          document.removeEventListener("keydown", this.onKeydown)
        }
      }
    </script>
    """
  end

  defp side_classes("top"), do: "bottom-full left-1/2 mb-1.5 -translate-x-1/2 origin-bottom"
  defp side_classes("bottom"), do: "top-full left-1/2 mt-1.5 -translate-x-1/2 origin-top"
  defp side_classes("left"), do: "right-full top-1/2 mr-1.5 -translate-y-1/2 origin-right"
  defp side_classes("right"), do: "left-full top-1/2 ml-1.5 -translate-y-1/2 origin-left"
end
