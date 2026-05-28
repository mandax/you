defmodule You.Repo.Migrations.AddConsents do
  use Ecto.Migration

  def change do
    create table(:consents) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :app_id, references(:apps, on_delete: :delete_all), null: false
      add :scopes, {:array, :string}, null: false
      add :granted_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false
      timestamps()
    end

    create unique_index(:consents, [:user_id, :app_id])
  end
end
