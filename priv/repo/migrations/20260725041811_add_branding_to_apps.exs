defmodule You.Repo.Migrations.AddBrandingToApps do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :logo_url, :string
      add :brand_color, :string
    end
  end
end
