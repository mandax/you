defmodule YouWeb.Components.Base.Input do
  @moduledoc """
  Text input primitive.

  Deliberately thin — no label, no error slot, no form coupling. It is the
  styled `<input>` the client has. Form-aware inputs belong in
  `YouWeb.CoreComponents`, which can wrap this.

  ## Examples

      <.base_input name="username" placeholder="admin" />
      <.base_input type="password" name="password" required />
  """
  use Phoenix.Component

  import YouWeb.Components.Base.Class

  @base "flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background file:border-0 file:bg-transparent file:text-sm file:font-medium placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50"

  attr :type, :string, default: "text"
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(accept autocomplete disabled form list max maxlength min minlength name
                pattern placeholder readonly required size step value)

  def base_input(assigns) do
    assigns = assign(assigns, :classes, cx([@base, assigns.class]))

    ~H"""
    <input type={@type} class={@classes} {@rest} />
    """
  end
end
