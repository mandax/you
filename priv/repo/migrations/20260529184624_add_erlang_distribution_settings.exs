defmodule You.Repo.Migrations.AddErlangDistributionSettings do
  use Ecto.Migration

  def up do
    execute(
      "INSERT OR IGNORE INTO settings (key, value, inserted_at, updated_at) VALUES ('erlang_node_name', 'you@you.internal', datetime('now'), datetime('now'))"
    )

    execute(
      "INSERT OR IGNORE INTO settings (key, value, inserted_at, updated_at) VALUES ('epmd_port', '4369', datetime('now'), datetime('now'))"
    )
  end

  def down do
    execute("DELETE FROM settings WHERE key IN ('erlang_node_name', 'epmd_port')")
  end
end
