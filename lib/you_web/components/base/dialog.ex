defmodule YouWeb.Components.Base.Dialog do
  @moduledoc """
  Modal dialog.

  Anatomy follows Base UI (`trigger`, backdrop, popup, close), but the popup is
  a native `<dialog>` opened with `showModal()`. That hands focus trapping,
  Escape-to-close, inertness of the background, and top-layer stacking to the
  platform instead of reimplementing them in JS, which is where hand-rolled
  modals usually get accessibility wrong.

  The backdrop is styled via `::backdrop`, so it covers the viewport correctly
  without a sibling element or a `z-index` fight.

  Two ways to drive it:

    * **Uncontrolled**: pass a `trigger` slot and the hook wires it up.
    * **From the server**: omit `trigger` and toggle `open`, e.g. after a
      `phx-click` sets some assign. Useful when opening depends on loaded data.

  `on_close` fires an event when the dialog closes by any route (Escape,
  backdrop, close button), so server state can follow along.

  ## Examples

      <.dialog id="session-detail">
        <:trigger>
          <.button variant="ghost" size="xs">Details</.button>
        </:trigger>
        <:title>Session</:title>
        <p>...</p>
      </.dialog>
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  attr :id, :string, required: true
  attr :open, :boolean, default: false
  attr :on_close, :string, default: nil, doc: "phx-click event pushed when the dialog closes"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :trigger
  slot :title
  slot :description
  slot :inner_block, required: true
  slot :footer

  def dialog(assigns) do
    ~H"""
    <div id={@id} phx-hook=".Dialog" data-open={@open && ""} data-on-close={@on_close}>
      <span :if={@trigger != []} data-part="trigger" class="contents">
        {render_slot(@trigger)}
      </span>

      <dialog
        data-part="popup"
        aria-labelledby={@title != [] && "#{@id}-title"}
        aria-describedby={@description != [] && "#{@id}-description"}
        class={
          cx([
            # m-auto restores native modal centering: Tailwind Preflight resets
            # `* { margin: 0 }`, which otherwise defeats the UA `dialog { margin:
            # auto }` and pins the popup to the top-left corner.
            "m-auto z-50 w-full max-w-lg rounded-lg border border-border bg-popover p-6 text-popover-foreground shadow-lg",
            "backdrop:bg-black/60 backdrop:backdrop-blur-sm",
            "open:animate-rise-in",
            @class
          ])
        }
        {@rest}
      >
        <div :if={@title != [] or @description != []} class="mb-4 flex flex-col space-y-1.5">
          <h2
            :if={@title != []}
            id={"#{@id}-title"}
            class="text-lg font-semibold leading-none tracking-tight"
          >
            {render_slot(@title)}
          </h2>
          <p :if={@description != []} id={"#{@id}-description"} class="text-sm text-muted-foreground">
            {render_slot(@description)}
          </p>
        </div>

        <button
          type="button"
          data-part="close"
          aria-label="Close"
          class="absolute right-4 top-4 rounded-sm opacity-70 transition-opacity hover:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
        >
          <span class="lucide-x size-4 block" />
        </button>

        {render_slot(@inner_block)}

        <div :if={@footer != []} class="mt-6 flex items-center justify-end gap-2">
          {render_slot(@footer)}
        </div>
      </dialog>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Dialog">
      export default {
        mounted() {
          this.dialog = this.el.querySelector('[data-part="popup"]')
          this.trigger = this.el.querySelector('[data-part="trigger"]')
          this.closeBtn = this.el.querySelector('[data-part="close"]')

          this.show = () => { if (!this.dialog.open) this.dialog.showModal() }
          this.hide = () => { if (this.dialog.open) this.dialog.close() }

          // Clicking the backdrop: the dialog element itself is the click target
          // only when the click landed outside the popup's own box.
          this.onDialogClick = (e) => {
            if (e.target !== this.dialog) return
            const box = this.dialog.getBoundingClientRect()
            const outside =
              e.clientX < box.left || e.clientX > box.right ||
              e.clientY < box.top || e.clientY > box.bottom
            if (outside) this.hide()
          }

          // Fires for Escape and for close() alike, so the server hears every route out.
          this.onClose = () => {
            const event = this.el.dataset.onClose
            if (event) this.pushEvent(event, {})
          }

          if (this.trigger) this.trigger.addEventListener("click", this.show)
          this.closeBtn.addEventListener("click", this.hide)
          this.dialog.addEventListener("click", this.onDialogClick)
          this.dialog.addEventListener("close", this.onClose)

          if (this.el.hasAttribute("data-open")) this.show()
        },

        updated() {
          this.el.hasAttribute("data-open") ? this.show() : this.hide()
        }
      }
    </script>
    """
  end
end
