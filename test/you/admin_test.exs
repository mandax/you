defmodule You.AdminTest do
  use You.DataCase, async: false

  alias You.Admin
  alias You.AccountsFixtures

  describe "promote_admin/1" do
    test "sets is_admin to true" do
      user = AccountsFixtures.user_fixture()
      assert {:ok, user} = Admin.promote_admin(user)
      assert user.is_admin
    end
  end

  describe "demote_admin/1" do
    test "sets is_admin to false" do
      user = AccountsFixtures.user_fixture() |> Admin.promote_admin!()
      assert {:ok, user} = Admin.demote_admin(user)
      refute user.is_admin
    end
  end

  describe "create_app/1" do
    test "registers a new app" do
      assert {:ok, app} =
               Admin.create_app(%{
                 slug: "sockeet",
                 name: "Sockeet",
                 callback_url: "https://sockeet.example.com/auth/callback"
               })

      assert app.slug == "sockeet"
      assert app.name == "Sockeet"
    end

    test "validates unique slug" do
      Admin.create_app(%{
        slug: "sockeet",
        name: "Sockeet",
        callback_url: "https://sockeet.example.com/auth/callback"
      })

      assert {:error, _} =
               Admin.create_app(%{
                 slug: "sockeet",
                 name: "Sockeet Dupe",
                 callback_url: "https://other.com/callback"
               })
    end
  end

  describe "lookup_app_by_callback/1" do
    setup do
      {:ok, app} =
        Admin.create_app(%{
          slug: "sockeet",
          name: "Sockeet",
          callback_url: "https://sockeet.example.com/auth/callback"
        })

      %{app: app}
    end

    test "matches the exact registered callback", %{app: app} do
      assert {:ok, found} =
               Admin.lookup_app_by_callback("https://sockeet.example.com/auth/callback")

      assert found.id == app.id
    end

    test "rejects a prefix-only match (open-redirect guard)" do
      # Would have matched under the old String.starts_with?/2 logic.
      assert :error =
               Admin.lookup_app_by_callback(
                 "https://sockeet.example.com/auth/callback.evil.com/x"
               )

      assert :error =
               Admin.lookup_app_by_callback("https://sockeet.example.com/auth/callback/sub")
    end
  end

  describe "bootstrap_admin/2" do
    test "creates user, confirms, and promotes to admin" do
      assert {:ok, user} = Admin.bootstrap_admin("admin@example.com", "a-strong-password!")
      assert user.is_admin
      assert user.email == "admin@example.com"
      assert user.confirmed_at != nil
    end

    test "idempotent — returns existing admin" do
      {:ok, user} = Admin.bootstrap_admin("admin@example.com", "a-strong-password!")
      assert {:ok, same} = Admin.bootstrap_admin("admin@example.com", "another-password")
      assert same.id == user.id
      assert same.is_admin
    end
  end
end
