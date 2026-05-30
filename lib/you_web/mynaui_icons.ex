defmodule YouWeb.MynauiIcons do
  @moduledoc """
  Compile-time SVG icon provider for MynaUI Icons.
  Usage: <.icon name="sun" class="size-5" />
  """
  use Phoenix.Component

  @icons_dir Path.expand("../../priv/static/assets/icons/mynaui", __DIR__)

  icon_files =
    @icons_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".svg"))

  # Read all SVGs at compile time into a map
  @icon_svgs Enum.reduce(icon_files, %{}, fn file, acc ->
               name = String.trim_trailing(file, ".svg")
               path = Path.join(@icons_dir, file)

               body =
                 path
                 |> File.read!()
                 |> String.replace(~r/<\?xml.*?\?>/, "")
                 |> String.replace(~r/<!DOCTYPE.*?>/, "")
                 |> String.trim()

               Map.put(acc, name, body)
             end)

  attr :name, :string, required: true, doc: "icon name (matches SVG filename minus .svg)"
  attr :class, :any, default: "size-5", doc: "CSS classes"

  def icon(assigns) do
    ~H"""
    {Phoenix.HTML.raw(render_icon(@name, @class))}
    """
  end

  defp render_icon(name, class) when is_list(class) do
    render_icon(name, Enum.join(class, " "))
  end

  defp render_icon(name, class) when is_binary(class) do
    case Map.get(@icon_svgs, name) do
      nil ->
        ~s(<span class="#{class}" data-missing-icon="#{name}">?</span>)

      svg ->
        svg |> String.replace("<svg", "<svg class=\"#{class}\"")
    end
  end
end
