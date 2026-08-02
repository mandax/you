defmodule You.Repo.Migrations.CreateRevokedJtis do
  use Ecto.Migration

  def up do
    create table(:revoked_jtis) do
      add :jti_hash, :binary, null: false
      add :subject, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:revoked_jtis, [:jti_hash])
    create index(:revoked_jtis, [:inserted_at])

    execute """
    INSERT OR IGNORE INTO revoked_jtis (jti_hash, subject, inserted_at)
    SELECT token, CAST(user_id AS TEXT), inserted_at
    FROM users_tokens WHERE context = 'jti_revoked'
    """

    execute "DELETE FROM users_tokens WHERE context = 'jti_revoked'"
  end

  def down do
    execute """
    INSERT OR IGNORE INTO users_tokens (token, context, user_id, inserted_at)
    SELECT jti_hash, 'jti_revoked', CAST(subject AS INTEGER), inserted_at
    FROM revoked_jtis WHERE subject GLOB '[0-9]*'
    """

    drop table(:revoked_jtis)
  end
end
