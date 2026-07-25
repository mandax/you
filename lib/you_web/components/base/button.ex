defmodule YouWeb.Components.Base.Button do
  @moduledoc """
  Button primitive.

  Renders a `<button>` by default, or an `<a>` when `navigate`, `patch`, or
  `href` is given. The link case still carries button styling, which is what
  Base UI's `render` prop does in the React version.

  ## Examples

      <.button>Save</.button>
      <.button variant="outline" size="sm" phx-click="refresh">Refresh</.button>
      <.button navigate={~p"/console"}>Console</.button>
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  @base "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:size-4 [&_svg]:shrink-0"

  @variants %{
    "default" => "bg-primary text-primary-foreground hover:bg-primary/90",
    "destructive" => "bg-destructive text-destructive-foreground hover:bg-destructive/90",
    "outline" => "border border-input bg-background hover:bg-accent hover:text-accent-foreground",
    "secondary" => "bg-secondary text-secondary-foreground hover:bg-secondary/80",
    "ghost" => "hover:bg-accent hover:text-accent-foreground",
    "link" => "text-primary underline-offset-4 hover:underline"
  }

  @sizes %{
    "default" => "h-10 px-4 py-2",
    "sm" => "h-9 rounded-md px-3",
    "xs" => "h-7 rounded-md px-2 text-xs",
    "lg" => "h-11 rounded-md px-8",
    "icon" => "h-10 w-10"
  }

  attr :variant, :string, default: "default", values: Map.keys(@variants)
  attr :size, :string, default: "default", values: Map.keys(@sizes)
  attr :type, :string, default: "button"
  attr :class, :any, default: nil
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value method download target rel)

  slot :inner_block, required: true

  def button(assigns) do
    assigns = assign(assigns, :classes, classes(assigns))

    ~H"""
    <.link
      :if={@navigate || @patch || @href}
      navigate={@navigate}
      patch={@patch}
      href={@href}
      class={@classes}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <button :if={!(@navigate || @patch || @href)} type={@type} class={@classes} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp classes(assigns) do
    cx([@base, @variants[assigns.variant], @sizes[assigns.size], assigns.class])
  end
end
