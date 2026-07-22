defmodule YouWeb.Components.Base.Separator do
  @moduledoc """
  Visual divider.

  Decorative by default (`role="none"`), matching Base UI: a rule that only
  separates visually should not be announced. Pass `decorative={false}` when the
  divider carries real meaning, and it becomes a proper `role="separator"` with
  its orientation exposed.

  ## Examples

      <.separator />
      <.separator orientation="vertical" class="mx-2" />
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  attr :orientation, :string, default: "horizontal", values: ~w(horizontal vertical)
  attr :decorative, :boolean, default: true
  attr :class, :any, default: nil
  attr :rest, :global

  def separator(assigns) do
    ~H"""
    <div
      role={if @decorative, do: "none", else: "separator"}
      aria-orientation={if !@decorative and @orientation == "vertical", do: "vertical"}
      class={
        cx([
          "shrink-0 bg-border",
          @orientation == "horizontal" && "h-px w-full",
          @orientation == "vertical" && "h-full w-px",
          @class
        ])
      }
      {@rest}
    />
    """
  end
end
