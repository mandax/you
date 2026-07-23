defmodule You.Repo.Migrations.AddFirstPartyToApps do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :first_party, :boolean, default: false, null: false
    end
  end
end
