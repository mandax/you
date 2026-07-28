defmodule You.Repo.Migrations.AddDefaultRoleToApps do
  use Ecto.Migration

  def up do
    alter table(:apps) do
      add :default_role, :string, default: "user"
    end

    # Existing rows resolved unassigned users to a hardcoded "user"; keep that
    # exact behaviour rather than leaving the column null.
    execute("UPDATE apps SET default_role = 'user' WHERE default_role IS NULL")
  end

  def down do
    alter table(:apps) do
      remove :default_role
    end
  end
end
