defmodule YouWeb.Components.Base.ColorPicker do
  @moduledoc """
  Colour field: a swatch that opens the platform picker, next to the hex value.

  The hex text input is the one that carries `name`, so the form submits the
  same string it always did and every existing validation still applies. The
  swatch is presentational and stays in sync in both directions.
  """
  use Phoenix.Component

  import YouWeb.CoreComponents, only: [error: 1, translate_error: 1]

  @doc """
  Renders a swatch plus a hex input.

  `value` is a 6-digit hex string or nil. Nil shows the placeholder swatch
  rather than defaulting to black, so "unset" and "black" stay distinguishable.

  Accepts a `field` the same way `YouWeb.CoreComponents.input/1` does — pass
  `field={@form[:brand_color]}` and `name`, `value` and changeset errors are
  all derived from it. Passing `name`/`value` directly still works for a
  caller with no form behind it (`app_live/show.ex`'s live-preview form,
  which posts straight from params rather than through a changeset).
  """
  attr :id, :string, required: true
  # No `default:` on `name`/`value`: a default would pre-populate the key in
  # `assigns` before the field-based clause below runs, and `assign_new/3`
  # only fills a key that is genuinely absent — the same reason
  # `CoreComponents.input/1` leaves its own `name`/`value` attrs without one.
  attr :name, :string
  attr :value, :any
  attr :field, Phoenix.HTML.FormField, default: nil, doc: "a form field, e.g. @form[:brand_color]"
  attr :label, :string, default: nil
  attr :placeholder, :string, default: "#7c3aed"
  attr :errors, :list, default: []

  def color_input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil)
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> color_input()
  end

  def color_input(assigns) do
    ~H"""
    <div class="mb-2" id={@id} phx-hook=".ColorPicker">
      <label :if={@label} for={"#{@id}-hex"} class="mb-1 block text-sm text-foreground">
        {@label}
      </label>

      <div class="flex items-center gap-2">
        <div class="relative size-10 shrink-0">
          <%!-- The native input is the picker; it sits transparent over a div
                that draws the swatch, because the control's own rendering is
                not themeable across browsers. --%>
          <div
            data-part="swatch"
            class="pointer-events-none absolute inset-0 rounded-md border border-input"
            style={@value && "background-color: #{@value}"}
          >
            <span
              :if={!@value}
              data-part="empty"
              class="absolute inset-0 rounded-md bg-[repeating-conic-gradient(hsl(var(--muted-foreground)/0.25)_0_25%,transparent_0_50%)] bg-[length:8px_8px]"
            />
          </div>
          <input
            type="color"
            data-part="picker"
            aria-label={@label || "Colour"}
            value={@value || @placeholder}
            class="absolute inset-0 size-full cursor-pointer opacity-0"
          />
        </div>

        <input
          type="text"
          id={"#{@id}-hex"}
          name={@name}
          value={@value}
          data-part="hex"
          placeholder={@placeholder}
          spellcheck="false"
          autocomplete="off"
          class="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
        />

        <button
          :if={@value}
          type="button"
          data-part="clear"
          aria-label="Clear colour"
          class="grid size-10 shrink-0 place-items-center rounded-md border border-input text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
        >
          <span class="lucide-x size-4 block" />
        </button>
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ColorPicker">
      export default {
        mounted() {
          this.picker = this.el.querySelector('[data-part="picker"]')
          this.hex = this.el.querySelector('[data-part="hex"]')
          this.swatch = this.el.querySelector('[data-part="swatch"]')
          this.empty = this.el.querySelector('[data-part="empty"]')
          this.clear = this.el.querySelector('[data-part="clear"]')

          const valid = (v) => /^#[0-9a-fA-F]{6}$/.test(v)

          // The hex field is what the form submits, so every change has to
          // reach it and dispatch input for phx-change to see it.
          this.push = (value) => {
            this.hex.value = value
            this.hex.dispatchEvent(new Event("input", {bubbles: true}))
            this.paint(value)
          }

          this.paint = (value) => {
            if (valid(value)) {
              this.swatch.style.backgroundColor = value
              if (this.empty) this.empty.style.display = "none"
            } else {
              this.swatch.style.backgroundColor = ""
              if (this.empty) this.empty.style.display = ""
            }
          }

          this.picker.addEventListener("input", () => this.push(this.picker.value))

          // Typing a partial value must not yank the picker around; only a
          // complete hex updates it.
          this.hex.addEventListener("input", () => {
            const value = this.hex.value.trim()
            if (valid(value)) this.picker.value = value
            this.paint(value)
          })

          if (this.clear) {
            this.clear.addEventListener("click", () => this.push(""))
          }

          this.paint(this.hex.value)
        },

        updated() {
          this.paint(this.hex.value)
        }
      }
    </script>
    """
  end
end
