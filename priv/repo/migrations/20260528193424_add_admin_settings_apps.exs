defmodule You.Repo.Migrations.AddAdminSettingsApps do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_admin, :boolean, default: false, null: false
    end

    create table(:settings) do
      add :key, :string, null: false
      add :value, :string, null: false
      timestamps()
    end

    create unique_index(:settings, [:key])

    create table(:apps) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :callback_url, :string, null: false
      timestamps()
    end

    create unique_index(:apps, [:slug])
  end
end
