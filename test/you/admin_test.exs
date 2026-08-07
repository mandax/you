defmodule You.AdminTest do
  use You.DataCase, async: false

  alias You.Admin
  alias You.Accounts
  alias You.AccountsFixtures
  alias You.AdminFixtures

  # The role filter matches an *explicit* assignment, deliberately — not the
  # effective role, which falls back to the app's default_role and would make
  # filtering by that default select the whole instance. Pinned because the
  # distinction is invisible from the UI: the Access column shows the
  # effective role, so an admin can see "admin" on a row the filter will not
  # find.
  describe "role filter semantics" do
    test "matches an explicit assignment" do
      {:ok, app, _} =
        You.Admin.create_app(%{
          slug: "rf-explicit",
          name: "RF",
          callback_url: "https://rf-explicit.example.com/cb",
          allowed_roles: ["user", "admin"]
        })

      granted = You.AccountsFixtures.user_fixture()
      # A second, unassigned user, or `== 1` is also the count of every user
      # and the assertion holds with the filter removed entirely.
      _ungranted = You.AccountsFixtures.user_fixture()
      {:ok, _} = You.Roles.set_role(app, granted, "admin")

      assert You.Admin.count_users_matching(%{role: "admin"}) == 1
      assert You.Admin.count_users_matching(%{}) == 2
    end

    test "does not match a user who only holds the app's default_role" do
      {:ok, app, _} =
        You.Admin.create_app(%{
          slug: "rf-default",
          name: "RF",
          callback_url: "https://rf-default.example.com/cb",
          default_role: "admin",
          allowed_roles: ["user", "admin"]
        })

      user = You.AccountsFixtures.user_fixture()

      assert You.Roles.role_for(app.slug, user.id) == "admin"
      assert You.Admin.count_users_matching(%{role: "admin"}) == 0
    end
  end

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
    # exists for, not just "reject everything weird". "myapp\n" covers the
    # `$`-matches-before-a-trailing-newline PCRE gotcha: `^...$` alone would
    # let it through as a slug containing exactly the whitespace this rule
    # exists to reject.
    test "rejects whitespace, dots, slashes, uppercase and a trailing newline" do
      for slug <- ["my app", "my.app", "my/app", "MyApp", "my\tapp", "myapp\n"] do
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

  # `new` is reserved so `/console/apps/new` (#130) always resolves to app
  # registration rather than being read as a slug — `/console/apps/:slug`
  # sits right below it in the router. The rule is enforced in
  # `App.changeset/2` itself, so it applies wherever a slug is written:
  # console, `create_app/1`, `update_app/2`, and the management API's
  # `PATCH /api/v1/apps/:id` alike, not just the console form.
  describe "reserved slug" do
    @valid_attrs %{slug: "myapp", name: "Myapp", callback_url: "https://myapp.example.com/cb"}

    test "create_app rejects new as a slug" do
      assert {:error, changeset} = Admin.create_app(Map.put(@valid_attrs, :slug, "new"))
      assert "is reserved" <> _ = hd(errors_on(changeset).slug)
    end

    test "update_app rejects renaming an existing app's slug to new" do
      {:ok, app, _secret} = Admin.create_app(@valid_attrs)

      assert {:error, changeset} = Admin.update_app(app, %{slug: "new"})
      assert "is reserved" <> _ = hd(errors_on(changeset).slug)

      # Rejected, not silently ignored: the app keeps its original slug.
      assert Admin.get_app!(app.id).slug == "myapp"
    end
  end

  describe "apps_with_invalid_slug/0" do
    alias You.Admin.App

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
      bad = AdminFixtures.insert_legacy_app!("legacy.app")

      assert [%App{id: id}] = Admin.apps_with_invalid_slug()
      assert id == bad.id
    end

    # This is the case #119's original audit doc got wrong: a bad slug does
    # not fail every future update to that app, only one that touches the
    # slug itself, because `validate_format/4` and `validate_length/3` run
    # through `validate_change/3`, which only checks a field already in
    # `changeset.changes`.
    test "an unrelated update to a legacy app still succeeds" do
      bad = AdminFixtures.insert_legacy_app!("legacy.app")

      assert {:ok, updated} = Admin.update_app(bad, %{name: "Renamed Legacy"})
      assert updated.name == "Renamed Legacy"
      assert updated.slug == "legacy.app"
    end

    test "renaming a legacy app to another invalid slug fails validation" do
      bad = AdminFixtures.insert_legacy_app!("legacy.app")

      assert {:error, changeset} = Admin.update_app(bad, %{slug: "still.invalid"})

      assert "must contain only lowercase letters, digits, hyphens, or underscores" in errors_on(
               changeset
             ).slug
    end
  end

  # #121: `hostname_label` is a nullable, DNS-label-constrained column kept
  # apart from `slug` (see `You.Admin.App`'s moduledoc). These pin the
  # format rule, the default (nil, never auto-filled from `slug`), and the
  # canonical-collision guard the milestone re-review added.
  describe "hostname_label" do
    alias You.Admin.App

    @valid_attrs %{slug: "hlapp", name: "HL App", callback_url: "https://hlapp.example.com/cb"}

    test "nil by default, and not auto-filled from slug" do
      assert {:ok, app, _secret} = Admin.create_app(@valid_attrs)
      assert app.hostname_label == nil
    end

    test "accepts a well-formed single DNS label" do
      for label <- ["acme", "acme-2", "a", String.duplicate("a", 63)] do
        changeset =
          App.changeset(%App{}, Map.put(@valid_attrs, :hostname_label, label))

        assert changeset.valid?,
               "expected #{inspect(label)} to be valid: #{inspect(errors_on(changeset))}"
      end
    end

    test "rejects a label with characters or shape a DNS label disallows" do
      for label <- [
            "ACME",
            "acme.com",
            "acme_co",
            "-acme",
            "acme-",
            "ac me",
            String.duplicate("a", 64)
          ] do
        changeset = App.changeset(%App{}, Map.put(@valid_attrs, :hostname_label, label))
        refute changeset.valid?, "expected #{inspect(label)} to be invalid"
        assert [_ | _] = errors_on(changeset).hostname_label
      end
    end

    test "blank normalizes to nil rather than an empty string" do
      {:ok, app, _secret} = Admin.create_app(Map.put(@valid_attrs, :hostname_label, "acme-blank"))
      assert {:ok, updated} = Admin.update_app(app, %{"hostname_label" => ""})
      assert updated.hostname_label == nil
    end

    test "must be unique" do
      assert {:ok, _app, _} =
               Admin.create_app(Map.put(@valid_attrs, :hostname_label, "taken"))

      other_attrs =
        %{@valid_attrs | slug: "hlapp2", callback_url: "https://hlapp2.example.com/cb"}
        |> Map.put(:hostname_label, "taken")

      assert {:error, changeset} = Admin.create_app(other_attrs)
      assert "has already been taken" in errors_on(changeset).hostname_label
    end

    test "renaming a slug does not touch hostname_label" do
      {:ok, app, _} = Admin.create_app(Map.put(@valid_attrs, :hostname_label, "stable"))
      {:ok, updated} = Admin.update_app(app, %{"name" => "Renamed"})
      assert updated.hostname_label == "stable"
    end

    # The milestone re-review: a label whose *rendered* hostname equals the
    # canonical host would let an app take over the instance's own front
    # door. Computed from the current template at write time, not a
    # hard-coded name.
    test "rejects a label that would render to the canonical host" do
      You.Settings.set(:hostname_template, "{label}")
      on_exit(fn -> You.Settings.set(:hostname_template, "") end)

      canonical = YouWeb.Endpoint.host()

      changeset = App.changeset(%App{}, Map.put(@valid_attrs, :hostname_label, canonical))
      refute changeset.valid?

      assert "would resolve to this instance's own canonical host" in errors_on(changeset).hostname_label
    end

    test "the same label is accepted with no template configured to collide against" do
      canonical = YouWeb.Endpoint.host()
      changeset = App.changeset(%App{}, Map.put(@valid_attrs, :hostname_label, canonical))
      assert changeset.valid?
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

  describe "list_users_with_stats/2 and count_users_matching/1" do
    test "email filter matches case-insensitively and paginates" do
      AccountsFixtures.user_fixture(%{email: "findme@example.com"})
      AccountsFixtures.user_fixture(%{email: "someoneelse@example.com"})

      assert Admin.count_users_matching(%{email: "FINDME"}) == 1

      assert [%{user: %{email: "findme@example.com"}}] =
               Admin.list_users_with_stats(%{email: "FINDME"})
    end

    test "status filter narrows to confirmed or unconfirmed" do
      confirmed = AccountsFixtures.user_fixture()
      unconfirmed = AccountsFixtures.unconfirmed_user_fixture()

      assert Admin.count_users_matching(%{status: "confirmed"}) == 1
      assert Admin.count_users_matching(%{status: "unconfirmed"}) == 1

      assert [%{user: found}] = Admin.list_users_with_stats(%{status: "confirmed"})
      assert found.id == confirmed.id

      assert [%{user: found}] = Admin.list_users_with_stats(%{status: "unconfirmed"})
      assert found.id == unconfirmed.id
    end

    test "app and role filters compose to an explicit assignment" do
      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "combo-app",
          name: "Combo App",
          callback_url: "https://combo-app.example.com/cb"
        })

      admin_user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      {:ok, _} = You.Roles.set_role(app, admin_user, "admin")

      assert Admin.count_users_matching(%{app_id: app.id, role: "admin"}) == 1
      assert [%{user: found}] = Admin.list_users_with_stats(%{app_id: app.id, role: "admin"})
      assert found.id == admin_user.id
      refute found.id == other.id
    end

    test "limit/offset page the filtered result" do
      for n <- 1..5, do: AccountsFixtures.user_fixture(%{email: "page#{n}@example.com"})

      page = Admin.list_users_with_stats(%{}, limit: 2, offset: 2)
      assert length(page) == 2
      assert Admin.count_users_matching(%{}) == 5
    end

    test "passkey and identity counts are scoped to exactly the users returned" do
      on_page = AccountsFixtures.user_fixture(%{email: "on-page@example.com"})
      off_page = AccountsFixtures.user_fixture(%{email: "off-page@example.com"})

      insert_passkey!(on_page)
      insert_passkey!(off_page)
      insert_passkey!(off_page)
      insert_federated_identity!(off_page)

      assert [%{user: found, passkeys: passkeys, identities: identities}] =
               Admin.list_users_with_stats(%{email: "on-page"})

      assert found.id == on_page.id
      assert passkeys == 1
      assert identities == 0
    end

    defp insert_passkey!(user) do
      %You.Accounts.Passkey{}
      |> You.Accounts.Passkey.changeset(%{
        user_id: user.id,
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :crypto.strong_rand_bytes(16)
      })
      |> You.Repo.insert!()
    end

    defp insert_federated_identity!(user) do
      %You.Accounts.FederatedIdentity{}
      |> You.Accounts.FederatedIdentity.changeset(%{
        user_id: user.id,
        provider: "google",
        subject: "sub-#{System.unique_integer([:positive])}",
        email: user.email
      })
      |> You.Repo.insert!()
    end
  end
end
