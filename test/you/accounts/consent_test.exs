defmodule You.Accounts.ConsentTest do
  use You.DataCase, async: false

  alias You.Accounts
  alias You.AccountsFixtures
  alias You.Admin

  describe "record_consent/3 and check_consent/2" do
    setup do
      user = AccountsFixtures.user_fixture()

      {:ok, app} =
        Admin.create_app(%{
          slug: "sockeet",
          name: "Sockeet",
          callback_url: "https://sockeet.example.com/auth/callback"
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

      {:ok, other_app} =
        Admin.create_app(%{
          slug: "other",
          name: "Other",
          callback_url: "https://other.example.com/callback"
        })

      assert Accounts.check_consent(user, other_app) == {:error, :no_consent}
    end
  end
end
