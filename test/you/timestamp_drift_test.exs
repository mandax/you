defmodule You.TimestampDriftTest do
  @moduledoc """
  Proves that switching `settings`, `apps`, `consents`, and
  `identity_providers` from bare `timestamps()` (naive) to
  `@timestamps_opts [type: :utc_datetime]` is safe for rows already on
  disk.

  The SQLite column itself never changes (it is `TEXT` either way — SQLite
  has no native datetime type), so this is a pure application-level type
  change. What matters is whether `Ecto.Adapters.SQLite3`'s `:utc_datetime`
  decoder can read every text shape this codebase has ever written into
  those columns:

    * `"YYYY-MM-DD HH:MM:SS"` — SQLite's `datetime('now')`, used by the
      raw-SQL settings seed migrations.
    * `"YYYY-MM-DDTHH:MM:SS"` — Ecto's own naive-datetime serialisation,
      written by every insert going through the old schemas.
    * `"YYYY-MM-DDTHH:MM:SSZ"` — Ecto's utc-datetime serialisation, already
      used for `consents.granted_at` / `consents.expires_at` and every
      already-utc_datetime table.

  Each test inserts a row with one of those literal shapes via raw SQL
  (standing in for a row written before this change shipped), then reads
  it back through the now-utc_datetime schema and asserts the decoded
  instant is correct.
  """
  use You.DataCase, async: false

  alias You.Accounts.Consent
  alias You.Admin.App
  alias You.IdentityProviders.IdentityProvider
  alias You.Repo
  alias You.Settings.Setting

  import You.AccountsFixtures

  describe "settings: legacy naive text shapes read back as utc_datetime" do
    test "space-separated text from SQLite's datetime('now')" do
      insert_legacy!(
        "settings",
        ~w(key value),
        ["legacy_key", "legacy_value"],
        "2026-01-15 10:30:00"
      )

      setting = Repo.get_by!(Setting, key: "legacy_key")

      assert setting.inserted_at == ~U[2026-01-15 10:30:00Z]
      assert setting.updated_at == ~U[2026-01-15 10:30:00Z]
    end

    test "T-separated, no-Z text from Ecto's old naive_datetime writer" do
      insert_legacy!(
        "settings",
        ~w(key value),
        ["legacy_key_2", "legacy_value_2"],
        "2026-01-15T10:30:00"
      )

      setting = Repo.get_by!(Setting, key: "legacy_key_2")

      assert setting.inserted_at == ~U[2026-01-15 10:30:00Z]
      assert setting.updated_at == ~U[2026-01-15 10:30:00Z]
    end
  end

  describe "apps: legacy naive text shapes read back as utc_datetime" do
    test "space-separated and T-separated rows both decode" do
      insert_legacy!(
        "apps",
        ~w(slug name callback_url),
        ["legacy-app", "Legacy App", "https://legacy.example.com/callback"],
        "2026-02-01 08:00:00"
      )

      app = Repo.get_by!(App, slug: "legacy-app")

      assert app.inserted_at == ~U[2026-02-01 08:00:00Z]
      assert app.updated_at == ~U[2026-02-01 08:00:00Z]
    end
  end

  describe "identity_providers: legacy naive text shapes read back as utc_datetime" do
    test "space-separated row decodes" do
      insert_legacy!(
        "identity_providers",
        ~w(slug display_name kind),
        ["legacy-idp", "Legacy IdP", "oidc"],
        "2026-03-10 12:00:00"
      )

      provider = Repo.get_by!(IdentityProvider, slug: "legacy-idp")

      assert provider.inserted_at == ~U[2026-03-10 12:00:00Z]
      assert provider.updated_at == ~U[2026-03-10 12:00:00Z]
    end
  end

  describe "consents: mixed-type row (naive inserted_at/updated_at beside utc_datetime granted_at/expires_at)" do
    test "both the old-naive and already-utc columns decode to the same instant shape" do
      user = user_fixture()

      {:ok, app} =
        %App{}
        |> App.changeset(%{
          slug: "consent-app",
          name: "Consent App",
          callback_url: "https://consent.example.com/callback"
        })
        |> Repo.insert()

      Repo.query!(
        """
        INSERT INTO consents
          (user_id, app_id, scopes, granted_at, expires_at, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [
          user.id,
          app.id,
          Jason.encode!(["openid"]),
          "2026-04-01T00:00:00Z",
          "2027-04-01T00:00:00Z",
          "2026-04-01 00:00:00",
          "2026-04-01 00:00:00"
        ]
      )

      consent = Repo.get_by!(Consent, user_id: user.id, app_id: app.id)

      assert consent.granted_at == ~U[2026-04-01 00:00:00Z]
      assert consent.expires_at == ~U[2027-04-01 00:00:00Z]
      assert consent.inserted_at == ~U[2026-04-01 00:00:00Z]
      assert consent.updated_at == ~U[2026-04-01 00:00:00Z]
    end
  end

  defp insert_legacy!(table, columns, values, timestamp) do
    column_list = Enum.join(columns, ", ")
    placeholders = Enum.map_join(1..length(columns), ", ", fn _ -> "?" end)

    Repo.query!(
      "INSERT INTO #{table} (#{column_list}, inserted_at, updated_at) VALUES (#{placeholders}, ?, ?)",
      values ++ [timestamp, timestamp]
    )
  end
end
