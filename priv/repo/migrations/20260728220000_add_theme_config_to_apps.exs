defmodule You.Repo.Migrations.AddThemeConfigToApps do
  use Ecto.Migration

  # Dark variants are nullable and fall back to the light value, so an app that
  # only sets one colour keeps working in both themes.
  #
  # theme_mode "system" follows the visitor's preference; "light"/"dark" force
  # one. Forcing has to happen at the document root — a wrapper element can add
  # the dark class but cannot remove an ancestor's.
  def change do
    alter table(:apps) do
      add :brand_color_dark, :string
      add :accent_color_dark, :string
      add :theme_mode, :string, default: "system"
    end
  end
end
