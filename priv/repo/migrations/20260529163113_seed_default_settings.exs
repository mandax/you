defmodule You.Repo.Migrations.SeedDefaultSettings do
  @moduledoc """
  Historical migration, left unedited on purpose.

  Its `INSERT` is built with `\#{setting.key}`/`\#{setting.value}` string
  interpolation rather than bound parameters. The values here are hardcoded
  literals, so there is no injection today, but do not copy this pattern —
  use `repo().insert_all/3` or parameter binding instead (see
  `20260802173000_drop_settings_seed_duplicates.exs` for an example).

  This migration has already run against every existing database, and
  editing an applied migration does not re-run it, so rewriting it here
  would not change any live installation's data and would only make the
  file disagree with what actually executed. `@defaults` in
  `lib/you/settings.ex` is the source of truth for these values; the rows
  this migration seeded (when they still match the seeded value) are
  removed by `20260802173000_drop_settings_seed_duplicates.exs`.
  """

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
