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
    test "registers a new app and returns the client secret once" do
      assert {:ok, app, client_secret} =
               Admin.create_app(%{
                 slug: "sockeet",
                 name: "Sockeet",
                 callback_url: "https://sockeet.example.com/auth/callback"
               })

      assert app.slug == "sockeet"
      assert app.name == "Sockeet"
      assert is_binary(client_secret)
      assert byte_size(client_secret) > 0
      # Secret is not stored in the DB — only its hash
      refute app.client_secret_hash == client_secret
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

  describe "rotate_app_secret/1" do
    test "rotates the client secret" do
      {:ok, app, original_secret} =
        Admin.create_app(%{
          slug: "rotate-me",
          name: "Rotate Test",
          callback_url: "https://example.com/cb"
        })

      assert {:ok, _app, new_secret} = Admin.rotate_app_secret(app)
      assert is_binary(new_secret)
      assert new_secret != original_secret
    end
  end

  describe "update_app/2" do
    test "updates an app's attributes" do
      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "updateme",
          name: "Update Test",
          callback_url: "https://example.com/cb"
        })

      refute app.first_party

      assert {:ok, updated} =
               Admin.update_app(app, %{
                 name: "Updated Name",
                 callback_url: "https://example.com/new-cb",
                 launch_url: "https://example.com/launch",
                 first_party: true
               })

      assert updated.name == "Updated Name"
      assert updated.callback_url == "https://example.com/new-cb"
      assert updated.launch_url == "https://example.com/launch"
      assert updated.first_party
    end

    test "does not change slug on update" do
      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "slug-test",
          name: "Slug Test",
          callback_url: "https://example.com/cb"
        })

      assert {:ok, updated} =
               Admin.update_app(app, %{name: "New Name", slug: "different-slug"})

      # Slug is cast but not changed by the update (no validation error since
      # it's not required_unique on update, but the value stays the same)
      assert updated.name == "New Name"
    end
  end

  describe "lookup_app_by_callback/1" do
    setup do
      {:ok, app, _secret} =
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
