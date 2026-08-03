defmodule You.Repo.Migrations.AddErlangCookieSetting do
  @moduledoc """
  Historical migration, left unedited on purpose.

  `@defaults` in `lib/you/settings.ex` is the source of truth for
  `erlang_cookie`; the row this migration seeded (when it still matches the
  seeded value) is removed by
  `20260802173000_drop_settings_seed_duplicates.exs`. Editing an applied
  migration does not re-run it, so this file is left as history.
  """

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
