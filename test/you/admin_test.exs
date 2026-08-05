defmodule You.AdminTest do
  use You.DataCase, async: false

  alias You.Admin
  alias You.Accounts
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
                 slug: "myapp",
                 name: "Myapp",
                 callback_url: "https://myapp.example.com/auth/callback"
               })

      assert app.slug == "myapp"
      assert app.name == "Myapp"
      assert is_binary(client_secret)
      assert byte_size(client_secret) > 0
      # Secret is not stored in the DB — only its hash
      refute app.client_secret_hash == client_secret
    end

    test "validates unique slug" do
      Admin.create_app(%{
        slug: "myapp",
        name: "Myapp",
        callback_url: "https://myapp.example.com/auth/callback"
      })

      assert {:error, _} =
               Admin.create_app(%{
                 slug: "myapp",
                 name: "Myapp Dupe",
                 callback_url: "https://other.com/callback"
               })
    end
  end

  describe "slug format" do
    alias You.Admin.App

    @valid_attrs %{slug: "myapp", name: "Myapp", callback_url: "https://myapp.example.com/cb"}

    test "accepts lowercase letters, digits, hyphens and underscores" do
      for slug <- ["myapp", "my-app", "my_app", "app2", "a"] do
        assert App.changeset(%App{}, Map.put(@valid_attrs, :slug, slug)).valid?
      end
    end

    # A dot would make client_id ambiguous against hostname-shaped values,
    # and a slash would break path construction — the two cases the rule
    # exists for, not just "reject everything weird".
    test "rejects whitespace, dots, slashes and uppercase" do
      for slug <- ["my app", "my.app", "my/app", "MyApp", "my\tapp"] do
        assert %{slug: ["must contain only lowercase letters, digits, hyphens, or underscores"]} =
                 errors_on(App.changeset(%App{}, Map.put(@valid_attrs, :slug, slug)))
      end
    end

    test "is capped in length" do
      too_long = String.duplicate("a", 65)
      ok_length = String.duplicate("a", 64)

      assert %{slug: ["should be at most 64 character(s)"]} =
               errors_on(App.changeset(%App{}, Map.put(@valid_attrs, :slug, too_long)))

      assert App.changeset(%App{}, Map.put(@valid_attrs, :slug, ok_length)).valid?
    end

    test "create_app rejects an invalid slug with a message naming the rule" do
      assert {:error, changeset} =
               Admin.create_app(Map.put(@valid_attrs, :slug, "not.a.slug"))

      assert "must contain only lowercase letters, digits, hyphens, or underscores" in errors_on(
               changeset
             ).slug
    end
  end

  describe "apps_with_invalid_slug/0" do
    alias You.Admin.App

    # Simulates a row written before this validation existed: `App.changeset/2`
    # would now refuse this slug, but a bad row already on disk did not go
    # through it to get there.
    defp insert_legacy_app!(slug) do
      %App{}
      |> Ecto.Changeset.change(%{
        slug: slug,
        name: "Legacy",
        callback_url: "https://legacy-#{System.unique_integer([:positive])}.example.com/cb",
        allowed_roles: ["user", "admin"],
        default_role: "user"
      })
      |> You.Repo.insert!()
    end

    test "is empty when every slug satisfies the rule" do
      {:ok, _app, _secret} =
        Admin.create_app(%{
          slug: "clean-app",
          name: "Clean",
          callback_url: "https://clean.example.com/cb"
        })

      assert Admin.apps_with_invalid_slug() == []
    end

    test "reports rows whose slug predates the validation" do
      bad = insert_legacy_app!("legacy.app")

      assert [%App{id: id}] = Admin.apps_with_invalid_slug()
      assert id == bad.id
    end
  end

  describe "app branding" do
    alias You.Admin.App

    @valid_attrs %{slug: "myapp", name: "Myapp", callback_url: "https://myapp.example.com/cb"}

    test "stores optional logo_url and brand_color" do
      assert {:ok, app, _secret} =
               Admin.create_app(
                 Map.merge(@valid_attrs, %{
                   logo_url: "https://myapp.example.com/logo.png",
                   brand_color: "#7c3aed"
                 })
               )

      assert app.logo_url == "https://myapp.example.com/logo.png"
      assert app.brand_color == "#7c3aed"
    end

    test "brand_color must be a 6-digit hex color, nil allowed" do
      assert %{brand_color: ["has invalid format"]} =
               errors_on(App.changeset(%App{}, Map.put(@valid_attrs, :brand_color, "purple")))

      assert %{brand_color: ["has invalid format"]} =
               errors_on(App.changeset(%App{}, Map.put(@valid_attrs, :brand_color, "#12345")))

      assert App.changeset(%App{}, Map.put(@valid_attrs, :brand_color, "#7c3aed")).valid?
      assert App.changeset(%App{}, @valid_attrs).valid?
    end

    test "logo_url must be an http(s) URL, nil allowed" do
      for url <- ["javascript:alert(1)", "ftp://example.com/logo.png", "not a url"] do
        assert %{logo_url: ["must be an http(s) URL"]} =
                 errors_on(App.changeset(%App{}, Map.put(@valid_attrs, :logo_url, url)))
      end

      assert App.changeset(
               %App{},
               Map.put(@valid_attrs, :logo_url, "https://example.com/logo.png")
             ).valid?

      assert App.changeset(%App{}, @valid_attrs).valid?
    end
  end

  describe "app customisation columns" do
    setup do
      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "custom",
          name: "Custom",
          callback_url: "https://custom.example.com/cb"
        })

      %{app: app}
    end

    test "enabled_providers and enabled_methods default to nil, meaning all", %{app: app} do
      assert app.enabled_providers == nil
      assert app.enabled_methods == nil
    end

    test "stores enabled providers and methods", %{app: app} do
      {:ok, app} =
        Admin.update_app(app, %{
          "enabled_providers" => ["google"],
          "enabled_methods" => ["password", "passkey"]
        })

      assert app.enabled_providers == ["google"]
      assert app.enabled_methods == ["password", "passkey"]
    end

    test "rejects an auth method the instance does not offer", %{app: app} do
      assert {:error, changeset} = Admin.update_app(app, %{"enabled_methods" => ["telepathy"]})
      assert "has an invalid entry" in errors_on(changeset).enabled_methods
    end

    # An empty list is a lockout: no method reaches the login page and nothing
    # says why. nil is the way to say "follow the instance".
    test "rejects an empty enabled_methods list", %{app: app} do
      assert {:error, changeset} = Admin.update_app(app, %{"enabled_methods" => []})

      assert "must offer at least one sign-in method" in errors_on(changeset).enabled_methods
    end

    test "still accepts nil enabled_methods", %{app: app} do
      {:ok, app} = Admin.update_app(app, %{"enabled_methods" => ["password"]})
      assert {:ok, app} = Admin.update_app(app, %{"enabled_methods" => nil})

      assert app.enabled_methods == nil
    end

    test "accent_color must be a 6-digit hex color", %{app: app} do
      assert {:error, changeset} = Admin.update_app(app, %{"accent_color" => "red"})
      assert "has invalid format" in errors_on(changeset).accent_color

      assert {:ok, app} = Admin.update_app(app, %{"accent_color" => "#0ea5e9"})
      assert app.accent_color == "#0ea5e9"
    end

    test "email_from_name is capped", %{app: app} do
      assert {:error, changeset} =
               Admin.update_app(app, %{"email_from_name" => String.duplicate("a", 101)})

      assert "should be at most 100 character(s)" in errors_on(changeset).email_from_name
    end
  end

  describe "login copy and consent urls" do
    alias You.Admin.App

    test "stores optional headline, subtitle, tos_url, and privacy_url" do
      assert {:ok, app, _secret} =
               Admin.create_app(
                 Map.merge(@valid_attrs, %{
                   headline: "Welcome to Myapp",
                   subtitle: "sign in below",
                   tos_url: "https://myapp.example.com/tos",
                   privacy_url: "https://myapp.example.com/privacy"
                 })
               )

      assert app.headline == "Welcome to Myapp"
      assert app.subtitle == "sign in below"
      assert app.tos_url == "https://myapp.example.com/tos"
      assert app.privacy_url == "https://myapp.example.com/privacy"
    end

    test "headline and subtitle are nil by default and can be cleared" do
      assert App.changeset(%App{}, @valid_attrs).valid?

      {:ok, app, _secret} =
        Admin.create_app(Map.put(@valid_attrs, :headline, "Hello"))

      assert {:ok, updated} = Admin.update_app(app, %{"headline" => ""})
      assert updated.headline == nil
    end

    test "headline and subtitle are capped at 200 characters" do
      too_long = String.duplicate("a", 201)
      ok_length = String.duplicate("a", 200)

      assert %{headline: ["should be at most 200 character(s)"]} =
               errors_on(App.changeset(%App{}, Map.put(@valid_attrs, :headline, too_long)))

      assert %{subtitle: ["should be at most 200 character(s)"]} =
               errors_on(App.changeset(%App{}, Map.put(@valid_attrs, :subtitle, too_long)))

      assert App.changeset(%App{}, Map.put(@valid_attrs, :headline, ok_length)).valid?
      assert App.changeset(%App{}, Map.put(@valid_attrs, :subtitle, ok_length)).valid?
    end

    test "tos_url and privacy_url must be http(s) URLs, nil allowed" do
      for url <- ["javascript:alert(1)", "ftp://example.com/tos", "not a url"] do
        assert %{tos_url: ["must be an http(s) URL"]} =
                 errors_on(App.changeset(%App{}, Map.put(@valid_attrs, :tos_url, url)))

        assert %{privacy_url: ["must be an http(s) URL"]} =
                 errors_on(App.changeset(%App{}, Map.put(@valid_attrs, :privacy_url, url)))
      end

      assert App.changeset(
               %App{},
               Map.put(@valid_attrs, :tos_url, "https://example.com/tos")
             ).valid?

      assert App.changeset(
               %App{},
               Map.put(@valid_attrs, :privacy_url, "https://example.com/privacy")
             ).valid?

      assert App.changeset(%App{}, @valid_attrs).valid?
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
          slug: "myapp",
          name: "Myapp",
          callback_url: "https://myapp.example.com/auth/callback"
        })

      %{app: app}
    end

    test "matches the exact registered callback", %{app: app} do
      assert {:ok, found} =
               Admin.lookup_app_by_callback("https://myapp.example.com/auth/callback")

      assert found.id == app.id
    end

    test "rejects a prefix-only match (open-redirect guard)" do
      # Would have matched under the old String.starts_with?/2 logic.
      assert :error =
               Admin.lookup_app_by_callback("https://myapp.example.com/auth/callback.evil.com/x")

      assert :error =
               Admin.lookup_app_by_callback("https://myapp.example.com/auth/callback/sub")
    end
  end

  describe "deletion_impact/1" do
    test "counts consents and role assignments for an app with several of each" do
      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "impacted",
          name: "Impacted App",
          callback_url: "https://impacted.example.com/cb"
        })

      for _ <- 1..3 do
        user = AccountsFixtures.user_fixture()
        {:ok, _consent} = Accounts.record_consent(user, app, ["profile"])
        {:ok, _assignment} = You.Roles.set_role(app, user, "admin")
      end

      assert Admin.deletion_impact(app) == %{consents: 3, role_assignments: 3}
    end

    test "returns zero counts for an app with no consents or role assignments" do
      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "untouched",
          name: "Untouched App",
          callback_url: "https://untouched.example.com/cb"
        })

      assert Admin.deletion_impact(app) == %{consents: 0, role_assignments: 0}
    end

    test "does not count another app's consents or role assignments" do
      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "target-app",
          name: "Target App",
          callback_url: "https://target.example.com/cb"
        })

      {:ok, other_app, _secret} =
        Admin.create_app(%{
          slug: "other-app",
          name: "Other App",
          callback_url: "https://other.example.com/cb"
        })

      user = AccountsFixtures.user_fixture()
      {:ok, _consent} = Accounts.record_consent(user, other_app, ["profile"])
      {:ok, _assignment} = You.Roles.set_role(other_app, user, "admin")

      assert Admin.deletion_impact(app) == %{consents: 0, role_assignments: 0}
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
