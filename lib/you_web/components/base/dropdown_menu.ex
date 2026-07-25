defmodule YouWeb.Components.Base.DropdownMenu do
  @moduledoc """
  Dropdown menu.

  Anatomy follows Base UI's `Menu`: `dropdown_menu` is the root with a `trigger`
  slot, and each entry is a separate `menu_item` component rather than a slot.
  That split is not cosmetic: slots cannot declare `:global` attributes, so a
  slot-based item could never accept the `phx-click` / `phx-value-*` bindings
  that make a menu item do anything. Composition also matches how the client
  used `Menu.Item`.

  Items render as `<button role="menuitem">` (or a link, given `navigate`/`href`)
  so they activate identically by mouse and keyboard.

  The colocated hook owns the interaction contract:

    * `ArrowDown`/`ArrowUp` move the highlight and wrap at the ends
    * `Home`/`End` jump to first/last
    * `Escape` closes and returns focus to the trigger
    * click outside closes
    * `aria-expanded` on the trigger, roving focus inside the menu

  Highlight state is `data-highlighted`, matching the Base UI selector the
  client's styles already target.

  ## Examples

      <.dropdown_menu id="user-menu">
        <:trigger>Account</:trigger>
        <.menu_item phx-click="profile">Profile</.menu_item>
        <.menu_item phx-click="logout">Log out</.menu_item>
      </.dropdown_menu>
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  attr :id, :string, required: true
  attr :align, :string, default: "start", values: ~w(start end)
  attr :class, :any, default: nil
  attr :trigger_class, :any, default: nil
  attr :rest, :global

  slot :trigger, required: true
  slot :inner_block, required: true

  def dropdown_menu(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".DropdownMenu"
      data-align={@align}
      class="relative inline-block text-left"
      {@rest}
    >
      <button
        type="button"
        data-part="trigger"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls={"#{@id}-popup"}
        class={cx(["inline-flex items-center", @trigger_class])}
      >
        {render_slot(@trigger)}
      </button>

      <div
        id={"#{@id}-popup"}
        role="menu"
        data-part="popup"
        hidden
        class={
          cx([
            "animate-palette-in absolute z-50 mt-1 min-w-[8rem] overflow-hidden rounded-md border border-border bg-popover p-1 text-popover-foreground shadow-md",
            @align == "start" && "left-0 origin-top-left",
            @align == "end" && "right-0 origin-top-right",
            @class
          ])
        }
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DropdownMenu">
      export default {
        mounted() {
          this.trigger = this.el.querySelector('[data-part="trigger"]')
          this.popup = this.el.querySelector('[data-part="popup"]')
          this.index = -1

          this.items = () =>
            Array.from(this.popup.querySelectorAll('[role="menuitem"]:not([data-disabled])'))

          this.highlight = (i) => {
            const items = this.items()
            if (items.length === 0) return
            // Wrap around at both ends.
            this.index = (i + items.length) % items.length
            items.forEach((el, n) => {
              if (n === this.index) {
                el.setAttribute("data-highlighted", "")
                el.focus()
              } else {
                el.removeAttribute("data-highlighted")
              }
            })
          }

          this.isOpen = () => !this.popup.hasAttribute("hidden")

          // The popup escapes overflow containers (tables with overflow-x-auto
          // would otherwise grow scrollbars or clip it): once visible, it is
          // positioned fixed against the trigger's viewport rect.
          this.open = () => {
            this.popup.removeAttribute("hidden")
            this.trigger.setAttribute("aria-expanded", "true")

            const rect = this.trigger.getBoundingClientRect()
            const popupRect = this.popup.getBoundingClientRect()
            this.popup.style.position = "fixed"
            this.popup.style.margin = "0"
            this.popup.style.top = `${rect.bottom + 4}px`
            this.popup.style.left = this.el.dataset.align === "end"
              ? `${rect.right - popupRect.width}px`
              : `${rect.left}px`

            this.highlight(0)
          }

          this.close = ({focusTrigger = false} = {}) => {
            if (!this.isOpen()) return
            this.popup.setAttribute("hidden", "")
            this.popup.style.position = ""
            this.popup.style.top = ""
            this.popup.style.left = ""
            this.popup.style.margin = ""
            this.trigger.setAttribute("aria-expanded", "false")
            this.items().forEach((el) => el.removeAttribute("data-highlighted"))
            this.index = -1
            if (focusTrigger) this.trigger.focus()
          }

          this.onTriggerClick = (e) => {
            e.stopPropagation()
            this.isOpen() ? this.close() : this.open()
          }

          this.onKeydown = (e) => {
            if (!this.isOpen()) {
              // Opening from the keyboard should land on a sensible end.
              if (document.activeElement === this.trigger && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
                e.preventDefault()
                this.open()
                if (e.key === "ArrowUp") this.highlight(-1)
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
            }
          }

          // Items are real buttons, so Enter/Space activate natively; just close after.
          this.onPopupClick = () => this.close({focusTrigger: true})
          this.onDocClick = (e) => { if (!this.el.contains(e.target)) this.close() }

          // Close when the pointer leaves the whole dropdown (with a small
          // grace period so crossing the fixed-position gap doesn't flicker).
          this.onMouseLeave = () => {
            this.leaveTimer = setTimeout(() => this.close(), 200)
          }
          this.onMouseEnter = () => clearTimeout(this.leaveTimer)

          this.trigger.addEventListener("click", this.onTriggerClick)
          this.popup.addEventListener("click", this.onPopupClick)
          this.el.addEventListener("keydown", this.onKeydown)
          this.el.addEventListener("mouseleave", this.onMouseLeave)
          this.el.addEventListener("mouseenter", this.onMouseEnter)
          document.addEventListener("click", this.onDocClick)
        },

        destroyed() {
          clearTimeout(this.leaveTimer)
          document.removeEventListener("click", this.onDocClick)
        }
      }
    </script>
    """
  end

  @item_class "relative flex w-full cursor-pointer select-none items-center gap-2 rounded-sm px-2 py-1.5 text-sm outline-none transition-colors data-[highlighted]:bg-accent data-[highlighted]:text-accent-foreground data-[disabled]:pointer-events-none data-[disabled]:opacity-50 [&_svg]:pointer-events-none [&_svg]:size-4 [&_svg]:shrink-0"

  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil
  attr :navigate, :string, default: nil
  attr :href, :any, default: nil
  attr :rest, :global, include: ~w(method download)

  slot :inner_block, required: true

  def menu_item(assigns) do
    assigns = assign(assigns, :classes, cx([@item_class, assigns.class]))

    ~H"""
    <.link
      :if={@navigate || @href}
      navigate={@navigate}
      href={@href}
      role="menuitem"
      class={@classes}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <button
      :if={!(@navigate || @href)}
      type="button"
      role="menuitem"
      data-disabled={@disabled && ""}
      disabled={@disabled}
      class={@classes}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end
end
