defmodule You.Repo.Migrations.DropSettingsSeedDuplicates do
  @moduledoc """
  Removes rows seeded by `20260529163113_seed_default_settings.exs`,
  `20260529184624_add_erlang_distribution_settings.exs`, and
  `20260529185554_add_erlang_cookie_setting.exs` when they still hold the
  exact value those migrations inserted.

  `You.Settings.get/1` already falls back to `@defaults` in
  `lib/you/settings.ex` when no row exists for a key, so a seeded row that
  still matches the value it was seeded with is pure duplication: a second,
  easily-forgotten copy of the default that can silently drift out of sync
  with `@defaults` (which is exactly what happened before this migration
  was written). Deleting such a row does not change what
  `Settings.get/1` returns for that key today, and it makes `@defaults`
  the only place that value is defined going forward.

  Rows whose value no longer matches the original seed are left untouched,
  because that means an operator genuinely configured the setting — this
  migration only removes duplicates of the default, never an override.

  The three seeding migrations above are intentionally left unedited: they
  already ran against every existing database, and editing an applied
  migration does not re-run it, so rewriting them would not change any
  live installation's data — only a new migration can do that. They also
  built their `INSERT` statements with string interpolation; this
  migration uses `repo().delete_all/2` and `repo().insert_all/3`, which
  bind parameters instead, so the injection-prone pattern is not repeated.
  """

  use Ecto.Migration
  import Ecto.Query

  @seeded %{
    "session_expiry_hours" => "24",
    "jwt_expiry_hours" => "1",
    "code_expiry_minutes" => "5",
    "magic_link_expiry_minutes" => "15",
    "erlang_node_name" => "you@you.example.com",
    "epmd_port" => "4369",
    "erlang_cookie" => ""
  }

  def up do
    for {key, value} <- @seeded do
      repo().delete_all(from(s in "settings", where: s.key == ^key and s.value == ^value))
    end
  end

  def down do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for {key, value} <- @seeded do
        %{key: key, value: value, inserted_at: now, updated_at: now}
      end

    repo().insert_all("settings", rows, on_conflict: :nothing, conflict_target: :key)
  end
end
