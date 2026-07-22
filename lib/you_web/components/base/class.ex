defmodule YouWeb.Components.Base.Class do
  @moduledoc """
  Class-list joining for base components.

  This is the HEEx counterpart to the client's `cn()` helper, with one
  important difference: `cn()` runs tailwind-merge, which *removes* earlier
  classes that conflict with later ones, so `cn("h-10", "h-9")` yields `h-9`.

  There is no tailwind-merge here. `cx/1` only flattens and joins, so both
  classes reach the DOM and the winner is decided by their order in the
  generated stylesheet, not by the order you wrote them. In practice that means:

    * **Additive** caller classes (spacing, layout, colors the variant doesn't
      set) work exactly as expected.
    * **Conflicting** caller classes are unreliable — `class="h-9"` on a
      `size="default"` button will not reliably beat the variant's `h-10`.

  So prefer adding a variant over overriding one from the call site. If a
  one-off really needs to win, use an arbitrary value (`class="h-[2.25rem]"`),
  which has no utility to collide with.
  """

  @doc """
  Joins class values into a single string.

  Accepts nested lists and drops `nil`, `false`, and empty strings, so
  conditional classes can be written inline:

      cx(["p-4", @active && "bg-accent", @class])
  """
  def cx(classes) do
    classes
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, false, true, ""]))
    |> Enum.join(" ")
    |> String.trim()
  end
end
