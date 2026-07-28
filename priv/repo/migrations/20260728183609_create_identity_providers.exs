defmodule You.Repo.Migrations.CreateIdentityProviders do
  use Ecto.Migration

  def change do
    create table(:identity_providers) do
      add :slug, :string, null: false
      add :display_name, :string, null: false
      add :kind, :string, null: false
      add :client_id, :string
      add :client_secret, :binary
      add :issuer, :string
      add :authorize_url, :string
      add :token_url, :string
      add :userinfo_url, :string
      add :scopes, :string
      add :icon, :string
      add :enabled, :boolean, null: false, default: true
      add :sort_order, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:identity_providers, [:slug])
  end
end
