defmodule You.Repo.Migrations.Add2faToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :totp_secret, :string
      add :totp_enabled, :boolean, default: false, null: false
    end

    create table(:recovery_codes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :code_hash, :string, null: false
      add :used, :boolean, default: false, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:recovery_codes, [:user_id])
  end
end
