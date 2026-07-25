defmodule You.Repo.Migrations.CreateWebhookEndpoints do
  use Ecto.Migration

  def change do
    create table(:webhook_endpoints) do
      add :url, :string, null: false
      add :secret, :string, null: false
      add :events, {:array, :string}, null: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end
  end
end
