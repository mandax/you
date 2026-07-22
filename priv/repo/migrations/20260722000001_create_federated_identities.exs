defmodule You.Repo.Migrations.CreateFederatedIdentities do
  use Ecto.Migration

  def change do
    create table(:federated_identities) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :subject, :string, null: false
      add :email, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:federated_identities, [:user_id])
    create unique_index(:federated_identities, [:provider, :subject])
  end
end
