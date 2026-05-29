defmodule You.Repo.Migrations.SeedDefaultSettings do
  use Ecto.Migration

  def up do
    defaults = [
      %{key: "session_expiry_hours", value: "24"},
      %{key: "jwt_expiry_hours", value: "1"},
      %{key: "code_expiry_minutes", value: "5"},
      %{key: "magic_link_expiry_minutes", value: "15"}
    ]

    for setting <- defaults do
      execute(
        "INSERT OR IGNORE INTO settings (key, value, inserted_at, updated_at) VALUES ('#{setting.key}', '#{setting.value}', datetime('now'), datetime('now'))"
      )
    end
  end

  def down do
    execute(
      "DELETE FROM settings WHERE key IN ('session_expiry_hours', 'jwt_expiry_hours', 'code_expiry_minutes', 'magic_link_expiry_minutes')"
    )
  end
end
