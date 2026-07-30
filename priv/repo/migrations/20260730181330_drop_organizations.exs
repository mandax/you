defmodule You.Repo.Migrations.DropOrganizations do
  use Ecto.Migration

  # Organizations never grew past a table and an admin screen: no JWT claim, no
  # role resolution, no billing, no consumer outside the console. The feature
  # shipped switched off and stayed that way, so dropping it costs nothing that
  # was in use. `down/0` restores the shape from 20260722224205, not the rows —
  # this is a real delete.

  def up do
    drop table(:memberships)
    drop table(:organizations)
  end

  def down do
    create table(:organizations) do
      add :name, :string, null: false
      add :slug, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:slug])

    create table(:memberships) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:memberships, [:organization_id, :user_id])
    create index(:memberships, [:user_id])
  end
end
