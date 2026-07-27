defmodule YouWeb.Components.Base.Sheet do
  @moduledoc """
  Side sheet: a dialog anchored to the edge of the viewport.

  Same platform bet as `dialog` — a native `<dialog>` opened with `showModal()`,
  so focus trapping, Escape, background inertness and top-layer stacking come
  from the browser — but sized as a full-height panel on the right. That shape
  suits *detail for the row you clicked*: it can stay open while you read the
  list behind it, and it has room for a stack of labelled controls that would
  make a centered modal tall and narrow.

  Server-driven only: toggle `open`, and `on_close` fires whenever it closes by
  any route, so the assign that opened it can be cleared.

  ## Examples

      <.sheet id="user-detail" open={@editing_user != nil} on_close="cancel_edit_user">
        <:title>{@editing_user.email}</:title>
        ...
      </.sheet>
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  attr :id, :string, required: true
  attr :open, :boolean, default: false
  attr :on_close, :string, default: nil, doc: "phx-click event pushed when the sheet closes"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :title
  slot :description
  slot :inner_block, required: true
  slot :footer

  def sheet(assigns) do
    ~H"""
    <div id={@id} phx-hook=".Sheet" data-open={@open && ""} data-on-close={@on_close}>
      <dialog
        data-part="popup"
        aria-labelledby={@title != [] && "#{@id}-title"}
        aria-describedby={@description != [] && "#{@id}-description"}
        class={
          cx([
            # Preflight zeroes the UA `margin: auto`, which is what would have
            # centered this; here that is wanted: pin right, full height.
            #
            # `open:flex` rather than a bare `flex`: a closed <dialog> is hidden
            # by the UA `display: none`, and any unconditional display utility
            # beats it, leaving the panel painted over the page permanently.
            "fixed inset-y-0 right-0 left-auto z-50 m-0 hidden h-screen max-h-screen w-full max-w-md flex-col open:flex",
            "border-l border-border bg-popover text-popover-foreground shadow-xl",
            "backdrop:bg-black/60 backdrop:backdrop-blur-sm",
            "open:animate-slide-in-right",
            @class
          ])
        }
        {@rest}
      >
        <header class="flex shrink-0 items-start justify-between gap-4 border-b border-border px-5 py-4">
          <div class="min-w-0 space-y-1">
            <h2
              :if={@title != []}
              id={"#{@id}-title"}
              class="truncate font-mono text-sm font-medium"
            >
              {render_slot(@title)}
            </h2>
            <p
              :if={@description != []}
              id={"#{@id}-description"}
              class="text-xs text-muted-foreground"
            >
              {render_slot(@description)}
            </p>
          </div>
          <button
            type="button"
            data-part="close"
            aria-label="Close"
            class="shrink-0 rounded-sm p-1 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            <span class="lucide-x size-4 block" />
          </button>
        </header>

        <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
          {render_slot(@inner_block)}
        </div>

        <footer
          :if={@footer != []}
          class="flex shrink-0 items-center justify-end gap-2 border-t border-border px-5 py-3"
        >
          {render_slot(@footer)}
        </footer>
      </dialog>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Sheet">
      export default {
        mounted() {
          this.dialog = this.el.querySelector('[data-part="popup"]')
          this.closeBtn = this.el.querySelector('[data-part="close"]')

          this.show = () => { if (!this.dialog.open) this.dialog.showModal() }
          this.hide = () => { if (this.dialog.open) this.dialog.close() }

          // Clicking the backdrop: the dialog is the click target only when the
          // pointer landed outside the panel's own box.
          this.onDialogClick = (e) => {
            if (e.target !== this.dialog) return
            const box = this.dialog.getBoundingClientRect()
            const outside =
              e.clientX < box.left || e.clientX > box.right ||
              e.clientY < box.top || e.clientY > box.bottom
            if (outside) this.hide()
          }

          this.onClose = () => {
            const event = this.el.dataset.onClose
            if (event) this.pushEvent(event, {})
          }

          this.closeBtn.addEventListener("click", this.hide)
          this.dialog.addEventListener("click", this.onDialogClick)
          this.dialog.addEventListener("close", this.onClose)

          if (this.el.hasAttribute("data-open")) this.show()
        },

        updated() {
          this.el.hasAttribute("data-open") ? this.show() : this.hide()
        },

        destroyed() {
          this.hide()
        }
      }
    </script>
    """
  end
end
