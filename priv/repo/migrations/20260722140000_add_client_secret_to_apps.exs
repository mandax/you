defmodule You.Repo.Migrations.AddClientSecretToApps do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :client_secret_hash, :binary
    end
  end
end
