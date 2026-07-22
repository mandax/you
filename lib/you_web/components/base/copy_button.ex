defmodule YouWeb.Components.Base.CopyButton do
  @moduledoc """
  Copies a value to the clipboard and confirms it.

  Clipboard access and the "Copied" flash are purely client-side — sending a
  round-trip to the server just to swap an icon would make the button feel
  laggy for no benefit — so all of it lives in a colocated hook.

  The value travels in a data attribute rather than the slot, so the button can
  copy something other than the label it shows (a whole code block, say).

  ## Examples

      <.copy_button id="copy-docker" value={@docker_run} />
      <.copy_button id="copy-curl" value={@curl} label="Copy request" />
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, default: "Copy"
  attr :copied_label, :string, default: "Copied"
  attr :class, :any, default: nil
  attr :rest, :global

  def copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-hook=".CopyButton"
      data-value={@value}
      data-label={@label}
      data-copied-label={@copied_label}
      class={
        cx([
          "inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground",
          @class
        ])
      }
      {@rest}
    >
      <span data-part="icon" class="lucide-copy size-3.5 block" />
      <span data-part="label">{@label}</span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyButton">
      export default {
        mounted() {
          this.icon = this.el.querySelector('[data-part="icon"]')
          this.label = this.el.querySelector('[data-part="label"]')

          this.reset = () => {
            this.icon.className = "lucide-copy size-3.5 block"
            this.label.textContent = this.el.dataset.label
          }

          this.onClick = async () => {
            try {
              await navigator.clipboard.writeText(this.el.dataset.value)
            } catch {
              return // clipboard blocked (insecure origin, denied permission)
            }
            this.icon.className = "lucide-check size-3.5 block text-signal-ok"
            this.label.textContent = this.el.dataset.copiedLabel
            clearTimeout(this.timer)
            this.timer = setTimeout(this.reset, 1400)
          }

          this.el.addEventListener("click", this.onClick)
        },

        destroyed() {
          clearTimeout(this.timer)
        }
      }
    </script>
    """
  end
end
