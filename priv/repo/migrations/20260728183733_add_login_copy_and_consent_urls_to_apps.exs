defmodule You.Repo.Migrations.AddLoginCopyAndConsentUrlsToApps do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :headline, :string
      add :subtitle, :string
      add :tos_url, :string
      add :privacy_url, :string
    end
  end
end
