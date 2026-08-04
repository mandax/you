defmodule You.Repo.Migrations.CreateInvitations do
  @moduledoc """
  Admin-issued invitations to an app.

  Before this, the only ways to onboard a user were self-registration and a
  SCIM push from an upstream directory — neither of which an operator can
  drive for one person.

  The token is stored as a SHA-256 hash, like every other emailed token here:
  a database read must not yield a working invitation link.
  """
  use Ecto.Migration

  def change do
    create table(:invitations) do
      add :email, :string, null: false
      add :token, :binary, null: false
      add :role, :string
      add :app_id, references(:apps, on_delete: :delete_all)
      add :invited_by_id, references(:users, on_delete: :nilify_all)
      add :accepted_at, :utc_datetime
      add :accepted_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:token])
    create index(:invitations, [:app_id])
    create index(:invitations, [:email])
  end
end
