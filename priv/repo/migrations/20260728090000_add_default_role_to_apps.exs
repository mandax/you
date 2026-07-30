defmodule You.Repo.Migrations.AddDefaultRoleToApps do
  use Ecto.Migration

  # SQLite backfills existing rows with the column default on ADD COLUMN, so
  # every app keeps resolving unassigned users to "user" until an admin
  # changes it — no separate backfill needed.
  def change do
    alter table(:apps) do
      add :default_role, :string, default: "user"
    end
  end
end
