defmodule You.Repo.Migrations.CreateFederatedLoginFlows do
  use Ecto.Migration

  def change do
    create table(:federated_login_flows) do
      add :state_hash, :binary, null: false, size: 32
      add :nonce_hash, :binary, null: false, size: 32
      add :provider, :string, null: false
      add :ctx, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:federated_login_flows, [:state_hash])
    create index(:federated_login_flows, [:inserted_at])
  end
end
