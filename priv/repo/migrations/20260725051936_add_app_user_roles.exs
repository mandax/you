defmodule You.Repo.Migrations.AddAppUserRoles do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :allowed_roles, {:array, :string}, null: false, default: ["user", "admin"]
    end

    create table(:app_user_roles) do
      add :app_id, references(:apps, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:app_user_roles, [:app_id, :user_id])
  end
end
