defmodule You.Repo.Migrations.AddErlangDistributionSettings do
  @moduledoc """
  Historical migration, left unedited on purpose.

  `@defaults` in `lib/you/settings.ex` is the source of truth for
  `erlang_node_name` and `epmd_port`; the rows this migration seeded (when
  they still match the seeded value) are removed by
  `20260802173000_drop_settings_seed_duplicates.exs`. Editing an applied
  migration does not re-run it, so this file is left as history.
  """

  use Ecto.Migration

  def up do
    execute(
      "INSERT OR IGNORE INTO settings (key, value, inserted_at, updated_at) VALUES ('erlang_node_name', 'you@you.example.com', datetime('now'), datetime('now'))"
    )

    execute(
      "INSERT OR IGNORE INTO settings (key, value, inserted_at, updated_at) VALUES ('epmd_port', '4369', datetime('now'), datetime('now'))"
    )
  end

  def down do
    execute("DELETE FROM settings WHERE key IN ('erlang_node_name', 'epmd_port')")
  end
end
