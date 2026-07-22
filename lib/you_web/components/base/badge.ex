defmodule YouWeb.Components.Base.Badge do
  @moduledoc """
  Small status pill.

  ## Examples

      <.badge>default</.badge>
      <.badge variant="success">active</.badge>
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  @base "inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold transition-colors focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"

  @variants %{
    "default" => "border-transparent bg-primary text-primary-foreground hover:bg-primary/80",
    "secondary" =>
      "border-transparent bg-secondary text-secondary-foreground hover:bg-secondary/80",
    "destructive" =>
      "border-transparent bg-destructive text-destructive-foreground hover:bg-destructive/80",
    "outline" => "text-foreground",
    "success" =>
      "border-transparent bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-300",
    "warning" =>
      "border-transparent bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-300",
    "error" => "border-transparent bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-300",
    "info" => "border-transparent bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-300",
    "neutral" =>
      "border-transparent bg-gray-100 text-gray-800 dark:bg-gray-800 dark:text-gray-300"
  }

  attr :variant, :string, default: "default", values: Map.keys(@variants)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    assigns = assign(assigns, :classes, cx([@base, @variants[assigns.variant], assigns.class]))

    ~H"""
    <div class={@classes} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
