defmodule You.Repo.Migrations.AddGuestUsers do
  @moduledoc """
  Anonymous accounts: a real user row with no credentials, so a consumer app
  can hold state for someone before they sign up and keep it when they do.

  A flag on `users` rather than a table of its own, because the whole point is
  that upgrading changes nothing about the row's identity — the id a consumer
  app has already written into its own schema stays the id it has.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_guest, :boolean, null: false, default: false
    end

    create index(:users, [:is_guest])
  end
end
