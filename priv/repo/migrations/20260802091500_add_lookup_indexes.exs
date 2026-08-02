defmodule You.Repo.Migrations.AddLookupIndexes do
  use Ecto.Migration

  def up do
    # `Admin.lookup_app_by_callback/1` runs on every interactive login and uses
    # `Repo.get_by/2`, which raises on two matching rows. Unique here rather
    # than in a changeset alone: the auth decision depends on it.
    create unique_index(:apps, [:callback_url])

    # SQLite scans the child table on every cascade delete unless an index
    # leads with the foreign key.
    create index(:app_user_roles, [:user_id])
    create index(:consents, [:app_id])
  end

  def down do
    drop index(:apps, [:callback_url])
    drop index(:app_user_roles, [:user_id])
    drop index(:consents, [:app_id])
  end
end
