defmodule You.Accounts.ConsentTest do
  use You.DataCase, async: false

  alias You.Accounts
  alias You.AccountsFixtures
  alias You.Admin

  describe "record_consent/3 and check_consent/2" do
    setup do
      user = AccountsFixtures.user_fixture()

      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "myapp",
          name: "Myapp",
          callback_url: "https://myapp.example.com/auth/callback"
        })

      %{user: user, app: app}
    end

    test "record_consent creates a consent record", %{user: user, app: app} do
      assert {:ok, consent} = Accounts.record_consent(user, app, ["email"])
      assert consent.user_id == user.id
      assert consent.app_id == app.id
      assert consent.scopes == ["email"]
    end

    test "check_consent returns true when consent exists and is valid", %{user: user, app: app} do
      {:ok, _} = Accounts.record_consent(user, app, ["email"])
      assert Accounts.check_consent(user, app) == {:ok, ["email"]}
    end

    test "check_consent returns error when no consent exists" do
      user = AccountsFixtures.user_fixture()

      {:ok, other_app, _secret} =
        Admin.create_app(%{
          slug: "other",
          name: "Other",
          callback_url: "https://other.example.com/callback"
        })

      assert Accounts.check_consent(user, other_app) == {:error, :no_consent}
    end
  end

  describe "list_consented_apps/1" do
    setup do
      user = AccountsFixtures.user_fixture()

      {:ok, app_a, _secret} =
        Admin.create_app(%{
          slug: "myapp",
          name: "Myapp",
          callback_url: "https://myapp.example.com/auth/callback"
        })

      {:ok, app_b, _secret} =
        Admin.create_app(%{
          slug: "other",
          name: "Other",
          callback_url: "https://other.example.com/callback"
        })

      %{user: user, app_a: app_a, app_b: app_b}
    end

    test "returns only apps the user has an active consent for", %{
      user: user,
      app_a: app_a
    } do
      {:ok, _} = Accounts.record_consent(user, app_a, ["email"])

      apps = Accounts.list_consented_apps(user)
      assert length(apps) == 1
      assert hd(apps).id == app_a.id
    end

    test "returns empty when user has no consents", %{user: user, app_a: _app_a, app_b: _app_b} do
      assert Accounts.list_consented_apps(user) == []
    end

    test "excludes apps where consent has expired", %{user: user, app_a: app_a, app_b: _app_b} do
      {:ok, consent} = Accounts.record_consent(user, app_a, ["email"])

      # Force the consent to expire
      You.Repo.update_all(
        Ecto.Query.from(c in Accounts.Consent, where: c.id == ^consent.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      assert Accounts.list_consented_apps(user) == []
    end
  end

  describe "revoke_app_access/2" do
    setup do
      user = AccountsFixtures.user_fixture()

      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "myapp",
          name: "Myapp",
          callback_url: "https://myapp.example.com/auth/callback"
        })

      %{user: user, app: app}
    end

    test "deletes the user's consent for the given app", %{user: user, app: app} do
      {:ok, _} = Accounts.record_consent(user, app, ["email"])
      assert length(Accounts.list_consented_apps(user)) == 1

      {count, _} = Accounts.revoke_app_access(user, app.id)
      assert count == 1
      assert Accounts.list_consented_apps(user) == []
    end

    test "is scoped to the given user", %{user: user, app: app} do
      other_user = AccountsFixtures.user_fixture()
      {:ok, _} = Accounts.record_consent(user, app, ["email"])
      {:ok, _} = Accounts.record_consent(other_user, app, ["email"])

      {count, _} = Accounts.revoke_app_access(user, app.id)
      assert count == 1

      # other_user's consent is untouched
      assert length(Accounts.list_consented_apps(other_user)) == 1
    end

    test "returns 0 when no consent exists", %{user: user, app: app} do
      {count, _} = Accounts.revoke_app_access(user, app.id)
      assert count == 0
    end
  end
end
