defmodule YouWeb.Components.Base.Select do
  @moduledoc """
  Select and multi-select.

  Anatomy follows Base UI's `Select`: a trigger showing the current value and a
  popup listbox of options. Unlike `dropdown_menu`, this models *a value being
  chosen*, so items are `role="option"` with `aria-selected`, the trigger is
  labelled by the selection, and the component carries state.

  It replaces both the native `<select>` (unstylable popup, no room for a
  checkmark or a description) and the "dropdown menu pretending to be a select"
  pattern, which had a real bug: menu items pushed `phx-value-value`, and
  LiveView reads a `<button>`'s own `value` property first, so every selection
  arrived at the server as `""` and the filter silently did nothing. The hook
  here builds the payload itself, so there is no attribute to collide with.

  Two ways to drive it, and they compose:

    * **Form**: pass `name`, and a hidden input carries the value. Selecting
      dispatches a bubbling `input` event, so an enclosing `phx-change` form
      picks it up like any other field.
    * **Event**: pass `on_change`, and selecting pushes that event with
      `%{"value" => value}` merged with `params`.

  ## Examples

      <.select
        id="filter-status"
        value={@filters["status"]}
        placeholder="all status"
        options={[%{value: "", label: "all status"}, %{value: "confirmed", label: "confirmed"}]}
        on_change="filter_users"
        params={%{"filter_key" => "status"}}
      />

      <.multi_select
        id="webhook-events"
        name="events"
        value={@selected_events}
        options={Enum.map(@events, &%{value: &1, label: &1})}
        placeholder="select events"
      />
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  @trigger_class "inline-flex h-8 items-center justify-between gap-1.5 rounded-md border border-input bg-background px-2.5 text-xs transition-colors hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-50"

  @popup_class "animate-palette-in absolute z-50 mt-1 max-h-72 min-w-[10rem] overflow-y-auto overflow-x-hidden rounded-md border border-border bg-popover p-1 text-popover-foreground shadow-md"

  @option_class "relative flex w-full cursor-pointer select-none items-center gap-2 rounded-sm py-1.5 pl-7 pr-2 text-left text-xs outline-none transition-colors data-[highlighted]:bg-accent data-[highlighted]:text-accent-foreground"

  attr :id, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true, doc: "list of %{value:, label:} maps"
  attr :name, :string, default: nil, doc: "renders a hidden input, for use inside a form"
  attr :placeholder, :string, default: "Select…"
  attr :on_change, :string, default: nil, doc: "LiveView event pushed on selection"
  attr :params, :map, default: %{}, doc: "extra params merged into the pushed event"
  attr :align, :string, default: "start", values: ~w(start end)
  attr :disabled, :boolean, default: false
  attr :label, :string, default: nil, doc: "overrides the trigger text"
  attr :class, :any, default: nil
  attr :rest, :global

  def select(assigns) do
    # Inside ~H, `@foo` reads assigns, so the shared class lists have to be
    # handed to the template rather than referenced as module attributes.
    assigns =
      assigns
      |> assign(
        :display,
        assigns.label || label_for(assigns.options, assigns.value) || assigns.placeholder
      )
      |> assign(
        trigger_class: @trigger_class,
        popup_class: @popup_class,
        option_class: @option_class
      )

    ~H"""
    <div
      id={@id}
      phx-hook=".Select"
      data-align={@align}
      data-on-change={@on_change}
      data-params={Jason.encode!(@params)}
      class="relative inline-block text-left"
      {@rest}
    >
      <input :if={@name} type="hidden" name={@name} value={@value} data-part="input" />

      <button
        type="button"
        data-part="trigger"
        role="combobox"
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls={"#{@id}-popup"}
        disabled={@disabled}
        class={cx([@trigger_class, "font-mono", @class])}
      >
        <span data-part="value" class="truncate">{@display}</span>
        <span class="lucide-chevron-down size-3 block shrink-0 opacity-60" />
      </button>

      <div
        id={"#{@id}-popup"}
        role="listbox"
        data-part="popup"
        hidden
        class={cx([@popup_class, @align == "end" && "right-0", @align == "start" && "left-0"])}
      >
        <button
          :for={option <- @options}
          type="button"
          role="option"
          data-part="option"
          data-value={option.value}
          aria-selected={to_string(to_string(option.value) == to_string(@value || ""))}
          class={cx([@option_class, "font-mono"])}
        >
          <span
            :if={to_string(option.value) == to_string(@value || "")}
            class="lucide-check absolute left-2 size-3 block"
          />
          {option.label}
        </button>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Select">
      export default {
        mounted() {
          this.trigger = this.el.querySelector('[data-part="trigger"]')
          this.popup = this.el.querySelector('[data-part="popup"]')
          this.input = this.el.querySelector('[data-part="input"]')
          this.index = -1

          this.options = () => Array.from(this.popup.querySelectorAll('[data-part="option"]'))
          this.isOpen = () => !this.popup.hasAttribute("hidden")

          this.highlight = (i) => {
            const options = this.options()
            if (options.length === 0) return
            this.index = (i + options.length) % options.length
            options.forEach((el, n) => {
              if (n === this.index) {
                el.setAttribute("data-highlighted", "")
                el.scrollIntoView({block: "nearest"})
              } else {
                el.removeAttribute("data-highlighted")
              }
            })
          }

          // The popup escapes overflow containers (a table with overflow-x-auto
          // would clip it or grow a scrollbar): once visible it is positioned
          // fixed against the trigger's viewport rect.
          this.open = () => {
            this.popup.removeAttribute("hidden")
            this.trigger.setAttribute("aria-expanded", "true")

            const rect = this.trigger.getBoundingClientRect()
            const popupRect = this.popup.getBoundingClientRect()
            const below = window.innerHeight - rect.bottom
            this.popup.style.position = "fixed"
            this.popup.style.margin = "0"
            this.popup.style.minWidth = `${rect.width}px`
            // Flip above the trigger when there is not enough room below.
            this.popup.style.top = below < popupRect.height + 8
              ? `${Math.max(8, rect.top - popupRect.height - 4)}px`
              : `${rect.bottom + 4}px`
            this.popup.style.left = this.el.dataset.align === "end"
              ? `${Math.max(8, rect.right - popupRect.width)}px`
              : `${rect.left}px`

            const selected = this.options().findIndex((el) => el.getAttribute("aria-selected") === "true")
            this.highlight(selected < 0 ? 0 : selected)
            this.popup.focus()
          }

          this.close = ({focusTrigger = false} = {}) => {
            if (!this.isOpen()) return
            this.popup.setAttribute("hidden", "")
            this.popup.style.position = ""
            this.popup.style.top = ""
            this.popup.style.left = ""
            this.popup.style.margin = ""
            this.popup.style.minWidth = ""
            this.options().forEach((el) => el.removeAttribute("data-highlighted"))
            this.index = -1
            if (focusTrigger) this.trigger.focus()
          }

          this.choose = (option) => {
            if (!option) return
            const value = option.dataset.value

            if (this.input) {
              this.input.value = value
              // Bubbles, so an enclosing phx-change form treats this like any
              // other field changing.
              this.input.dispatchEvent(new Event("input", {bubbles: true}))
            }

            const event = this.el.dataset.onChange
            if (event) {
              const params = JSON.parse(this.el.dataset.params || "{}")
              this.pushEvent(event, {...params, value})
            }

            // Optimistic: the server re-renders anyway, but the trigger should
            // not lag behind the click.
            this.el.querySelector('[data-part="value"]').textContent = option.textContent.trim()
            this.close({focusTrigger: true})
          }

          this.onTriggerClick = (e) => {
            e.stopPropagation()
            this.isOpen() ? this.close() : this.open()
          }

          this.onPopupClick = (e) => {
            const option = e.target.closest('[data-part="option"]')
            if (option) this.choose(option)
          }

          this.onKeydown = (e) => {
            if (!this.isOpen()) {
              if (document.activeElement === this.trigger && ["ArrowDown", "ArrowUp", "Enter", " "].includes(e.key)) {
                e.preventDefault()
                this.open()
              }
              return
            }

            switch (e.key) {
              case "ArrowDown": e.preventDefault(); this.highlight(this.index + 1); break
              case "ArrowUp":   e.preventDefault(); this.highlight(this.index - 1); break
              case "Home":      e.preventDefault(); this.highlight(0); break
              case "End":       e.preventDefault(); this.highlight(-1); break
              case "Escape":    e.preventDefault(); this.close({focusTrigger: true}); break
              case "Tab":       this.close(); break
              case "Enter":
              case " ":
                e.preventDefault()
                this.choose(this.options()[this.index])
                break
            }
          }

          this.onDocClick = (e) => { if (!this.el.contains(e.target)) this.close() }

          this.trigger.addEventListener("click", this.onTriggerClick)
          this.popup.addEventListener("click", this.onPopupClick)
          this.el.addEventListener("keydown", this.onKeydown)
          document.addEventListener("click", this.onDocClick)
        },

        destroyed() {
          document.removeEventListener("click", this.onDocClick)
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true, doc: "hidden inputs render as name[value]=true"
  attr :value, :list, default: [], doc: "currently selected values"
  attr :options, :list, required: true, doc: "list of %{value:, label:} maps"
  attr :placeholder, :string, default: "Select…"
  attr :group_by, :any, default: nil, doc: "1-arity fun mapping an option to a group heading"
  attr :searchable, :boolean, default: true
  attr :unit, :string, default: "selected", doc: "trigger summary wording: \"3 <unit>\""
  attr :class, :any, default: nil
  attr :rest, :global

  def multi_select(assigns) do
    assigns =
      assign(assigns,
        groups: group_options(assigns.options, assigns.group_by),
        selected: MapSet.new(Enum.map(assigns.value, &to_string/1)),
        trigger_class: @trigger_class,
        popup_class: @popup_class,
        option_class: @option_class
      )

    ~H"""
    <div
      id={@id}
      phx-hook=".MultiSelect"
      data-name={@name}
      class="relative inline-block w-full text-left"
      {@rest}
    >
      <div data-part="inputs" class="contents">
        <input
          :for={value <- @value}
          type="hidden"
          name={"#{@name}[#{value}]"}
          value="true"
          data-value={value}
        />
      </div>

      <button
        type="button"
        data-part="trigger"
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls={"#{@id}-popup"}
        class={cx([@trigger_class, "w-full font-mono", @class])}
      >
        <span
          data-part="summary"
          data-placeholder={@placeholder}
          data-unit={@unit}
          class="truncate"
        >
          {summary(@value, @placeholder, @unit)}
        </span>
        <span class="lucide-chevron-down size-3 block shrink-0 opacity-60" />
      </button>

      <div
        id={"#{@id}-popup"}
        role="listbox"
        aria-multiselectable="true"
        data-part="popup"
        hidden
        class={cx([@popup_class, "left-0 w-full"])}
      >
        <div :if={@searchable} class="p-1">
          <input
            type="text"
            data-part="search"
            placeholder="search…"
            autocomplete="off"
            class="h-7 w-full rounded-sm border border-input bg-background px-2 font-mono text-xs placeholder:text-muted-foreground/60 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>

        <div :for={{heading, options} <- @groups} data-part="group">
          <div
            :if={heading}
            class="px-2 pb-0.5 pt-1.5 font-mono text-[10px] uppercase tracking-widest text-muted-foreground/70"
          >
            {heading}
          </div>
          <button
            :for={option <- options}
            type="button"
            role="option"
            data-part="option"
            data-value={option.value}
            data-label={option.label}
            aria-selected={to_string(MapSet.member?(@selected, to_string(option.value)))}
            class={cx([@option_class, "font-mono"])}
          >
            <span
              data-part="check"
              class={[
                "lucide-check absolute left-2 size-3 block",
                !MapSet.member?(@selected, to_string(option.value)) && "invisible"
              ]}
            />
            {option.label}
          </button>
        </div>

        <div class="mt-1 flex items-center justify-between border-t border-border px-2 pt-1.5 pb-0.5">
          <button
            type="button"
            data-part="all"
            class="font-mono text-[11px] text-muted-foreground hover:text-foreground"
          >
            select all
          </button>
          <button
            type="button"
            data-part="none"
            class="font-mono text-[11px] text-muted-foreground hover:text-foreground"
          >
            clear
          </button>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MultiSelect">
      export default {
        mounted() {
          this.trigger = this.el.querySelector('[data-part="trigger"]')
          this.popup = this.el.querySelector('[data-part="popup"]')
          this.summary = this.el.querySelector('[data-part="summary"]')
          this.inputs = this.el.querySelector('[data-part="inputs"]')
          this.search = this.el.querySelector('[data-part="search"]')

          this.options = () => Array.from(this.popup.querySelectorAll('[data-part="option"]'))
          this.selected = () => this.options().filter((el) => el.getAttribute("aria-selected") === "true")
          this.isOpen = () => !this.popup.hasAttribute("hidden")

          // Selection lives in the DOM (aria-selected on each option) and the
          // hidden inputs are rebuilt from it, so a plain form submit carries
          // the same `name[value]=true` shape a checkbox list would have sent.
          this.sync = () => {
            const chosen = this.selected()
            const name = this.el.dataset.name
            this.inputs.innerHTML = ""
            chosen.forEach((el) => {
              const input = document.createElement("input")
              input.type = "hidden"
              input.name = `${name}[${el.dataset.value}]`
              input.value = "true"
              this.inputs.appendChild(input)
            })
            this.summary.textContent =
              chosen.length === 0
                ? this.summary.dataset.placeholder
                : chosen.length === 1
                  ? chosen[0].dataset.label
                  : `${chosen.length} ${this.summary.dataset.unit}`
          }

          this.toggle = (option) => {
            const on = option.getAttribute("aria-selected") === "true"
            option.setAttribute("aria-selected", on ? "false" : "true")
            option.querySelector('[data-part="check"]').classList.toggle("invisible", on)
            this.sync()
          }

          this.filter = (query) => {
            const q = query.trim().toLowerCase()
            this.options().forEach((el) => {
              el.hidden = q !== "" && !el.dataset.value.toLowerCase().includes(q)
            })
            // Hide a group heading whose options are all filtered out.
            this.popup.querySelectorAll('[data-part="group"]').forEach((group) => {
              const visible = Array.from(group.querySelectorAll('[data-part="option"]')).some((el) => !el.hidden)
              group.hidden = !visible
            })
          }

          this.open = () => {
            this.popup.removeAttribute("hidden")
            this.trigger.setAttribute("aria-expanded", "true")
            if (this.search) this.search.focus()
          }

          this.close = () => {
            if (!this.isOpen()) return
            this.popup.setAttribute("hidden", "")
            this.trigger.setAttribute("aria-expanded", "false")
          }

          this.trigger.addEventListener("click", (e) => {
            e.stopPropagation()
            this.isOpen() ? this.close() : this.open()
          })

          this.popup.addEventListener("click", (e) => {
            const option = e.target.closest('[data-part="option"]')
            if (option) return this.toggle(option)
            if (e.target.closest('[data-part="all"]')) {
              this.options().filter((el) => !el.hidden).forEach((el) => {
                el.setAttribute("aria-selected", "true")
                el.querySelector('[data-part="check"]').classList.remove("invisible")
              })
              this.sync()
            }
            if (e.target.closest('[data-part="none"]')) {
              this.options().forEach((el) => {
                el.setAttribute("aria-selected", "false")
                el.querySelector('[data-part="check"]').classList.add("invisible")
              })
              this.sync()
            }
          })

          if (this.search) {
            this.search.addEventListener("input", () => this.filter(this.search.value))
            // Keep typing from submitting the enclosing form.
            this.search.addEventListener("keydown", (e) => {
              if (e.key === "Enter") e.preventDefault()
              if (e.key === "Escape") { e.preventDefault(); this.close(); this.trigger.focus() }
            })
          }

          this.onDocClick = (e) => { if (!this.el.contains(e.target)) this.close() }
          document.addEventListener("click", this.onDocClick)
        },

        destroyed() {
          document.removeEventListener("click", this.onDocClick)
        }
      }
    </script>
    """
  end

  defp label_for(options, value) do
    value = to_string(value || "")
    Enum.find_value(options, &if(to_string(&1.value) == value, do: &1.label))
  end

  defp summary([], placeholder, _unit), do: placeholder
  defp summary([one], _placeholder, _unit), do: to_string(one)
  defp summary(values, _placeholder, unit), do: "#{length(values)} #{unit}"

  defp group_options(options, nil), do: [{nil, options}]

  defp group_options(options, group_by) do
    options
    |> Enum.group_by(group_by)
    |> Enum.sort_by(fn {heading, _} -> heading end)
  end
end
