defmodule You.Repo.Migrations.AddErlangCookieSetting do
  use Ecto.Migration

  def up do
    execute(
      "INSERT OR IGNORE INTO settings (key, value, inserted_at, updated_at) VALUES ('erlang_cookie', '', datetime('now'), datetime('now'))"
    )
  end

  def down do
    execute("DELETE FROM settings WHERE key = 'erlang_cookie'")
  end
end
