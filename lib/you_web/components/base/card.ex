defmodule YouWeb.Components.Base.Card do
  @moduledoc """
  Card surface and its parts.

  Anatomy mirrors the client's card: `card` wraps `card_header`
  (`card_title` + `card_description`), `card_content`, and `card_footer`.

  ## Examples

      <.card>
        <.card_header>
          <.card_title>Instances</.card_title>
          <.card_description>Chrome processes on this node</.card_description>
        </.card_header>
        <.card_content>...</.card_content>
      </.card>
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={cx(["rounded-lg border bg-card text-card-foreground shadow-sm", @class])} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card_header(assigns) do
    ~H"""
    <div class={cx(["flex flex-col space-y-1.5 p-6", @class])} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card_title(assigns) do
    ~H"""
    <div class={cx(["text-2xl font-semibold leading-none tracking-tight", @class])} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card_description(assigns) do
    ~H"""
    <div class={cx(["text-sm text-muted-foreground", @class])} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card_content(assigns) do
    ~H"""
    <div class={cx(["p-6 pt-0", @class])} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card_footer(assigns) do
    ~H"""
    <div class={cx(["flex items-center p-6 pt-0", @class])} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
