defmodule YouWeb.AppLive.ShowTest do
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import You.DataCase, only: [errors_on: 1]

  alias You.{Admin, Roles}

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)

    {:ok, app, _secret} =
      Admin.create_app(%{
        slug: "edit-me",
        name: "Edit Me",
        callback_url: "https://edit.example.com/cb"
      })

    %{conn: log_in_user(conn, user), app: app, admin: user}
  end

  test "every tab mounts", %{conn: conn, app: app} do
    for tab <- ~w(overview login roles members credentials) do
      {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.slug}?tab=#{tab}")
      assert html =~ app.name
    end
  end

  test "an unknown tab falls back to overview", %{conn: conn, app: app} do
    {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.slug}?tab=nonsense")
    assert html =~ "Identity and URLs"
  end

  test "an unknown slug 404s", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/console/apps/nope") end
  end

  # `require_admin` 404s rather than redirecting, so the page does not confirm
  # its own existence to a non-admin.
  test "a non-admin cannot reach the page", %{app: app} do
    conn =
      build_conn()
      |> log_in_user(You.AccountsFixtures.user_fixture())
      |> get(~p"/console/apps/#{app.slug}")

    assert conn.status == 404
  end

  test "an anonymous visitor cannot reach the page", %{app: app} do
    assert {:error, {:redirect, %{to: to}}} = live(build_conn(), ~p"/console/apps/#{app.slug}")
    assert to =~ "/users/log-in"
  end

  describe "overview" do
    test "changes name and toggles first_party", %{conn: conn, app: app} do
      refute app.first_party

      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}")

      html =
        lv
        |> form("#app-overview-form", %{
          "name" => "Renamed App",
          "callback_url" => "https://edit.example.com/cb",
          "launch_url" => "https://edit.example.com/launch",
          "first_party" => "true"
        })
        |> render_submit()

      assert html =~ "App updated"

      updated = Admin.get_app!(app.id)
      assert updated.name == "Renamed App"
      assert updated.launch_url == "https://edit.example.com/launch"
      assert updated.first_party
    end

    # An unchecked box submits the hidden "false" input that `input/1` renders
    # alongside every checkbox, so the field is present either way.
    test "unchecking first_party turns it off", %{conn: conn, app: app} do
      {:ok, _app} = Admin.update_app(app, %{"first_party" => true})

      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}")

      lv
      |> form("#app-overview-form", %{
        "name" => app.name,
        "callback_url" => app.callback_url,
        "first_party" => "false"
      })
      |> render_submit()

      refute Admin.get_app!(app.id).first_party
    end
  end

  describe "login branding" do
    test "sets and clears branding", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-branding-form", %{
          "logo_url" => "https://edit.example.com/logo.png",
          "brand_color" => "#7c3aed"
        })
        |> render_submit()

      assert html =~ "Branding updated"

      updated = Admin.get_app!(app.id)
      assert updated.logo_url == "https://edit.example.com/logo.png"
      assert updated.brand_color == "#7c3aed"

      lv
      |> form("#app-branding-form", %{"logo_url" => "", "brand_color" => "#0ea5e9"})
      |> render_submit()

      cleared = Admin.get_app!(app.id)
      assert cleared.logo_url == nil
      assert cleared.brand_color == "#0ea5e9"
    end

    test "sets and clears headline and subtitle through the branding form", %{
      conn: conn,
      app: app
    } do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-branding-form", %{
          "headline" => "Welcome to Edit Me",
          "subtitle" => "sign in to keep going"
        })
        |> render_submit()

      assert html =~ "Branding updated"

      updated = Admin.get_app!(app.id)
      assert updated.headline == "Welcome to Edit Me"
      assert updated.subtitle == "sign in to keep going"

      lv
      |> form("#app-branding-form", %{"headline" => "", "subtitle" => ""})
      |> render_submit()

      cleared = Admin.get_app!(app.id)
      assert cleared.headline == nil
      assert cleared.subtitle == nil
    end

    test "sets and clears tos_url and privacy_url through the consent screen form", %{
      conn: conn,
      app: app
    } do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-consent-form", %{
          "tos_url" => "https://edit.example.com/tos",
          "privacy_url" => "https://edit.example.com/privacy"
        })
        |> render_submit()

      assert html =~ "Consent screen updated"

      updated = Admin.get_app!(app.id)
      assert updated.tos_url == "https://edit.example.com/tos"
      assert updated.privacy_url == "https://edit.example.com/privacy"

      lv
      |> form("#app-consent-form", %{"tos_url" => "", "privacy_url" => ""})
      |> render_submit()

      cleared = Admin.get_app!(app.id)
      assert cleared.tos_url == nil
      assert cleared.privacy_url == nil
    end
  end

  describe "login preview" do
    test "renders saved branding on mount", %{conn: conn, app: app} do
      {:ok, _app} =
        Admin.update_app(app, %{
          "logo_url" => "https://edit.example.com/logo.png",
          "brand_color" => "#7c3aed"
        })

      {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      assert html =~ ~s(src="https://edit.example.com/logo.png")
      assert html =~ "color: #7c3aed"
    end

    test "tracks unsaved edits without persisting them", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-branding-form", %{
          "logo_url" => "https://edit.example.com/draft.png",
          "brand_color" => "#0ea5e9"
        })
        |> render_change()

      assert html =~ ~s(src="https://edit.example.com/draft.png")
      assert html =~ "color: #0ea5e9"

      # Preview only — nothing written until the form is submitted.
      assert Admin.get_app!(app.id).logo_url == nil
      assert Admin.get_app!(app.id).brand_color == nil
    end

    test "a blank field previews as no value, not an empty attribute", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-branding-form", %{"logo_url" => "", "brand_color" => ""})
        |> render_change()

      refute html =~ ~s(src="")
      refute html =~ "color: ;"
      assert html =~ "lucide-lock"
    end

    test "saving resets the draft to the stored values", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      lv
      |> form("#app-branding-form", %{"logo_url" => "", "brand_color" => "#0ea5e9"})
      |> render_submit()

      assert render(lv) =~ "color: #0ea5e9"
      assert Admin.get_app!(app.id).brand_color == "#0ea5e9"
    end

    test "links out to the real login page for this app", %{conn: conn, app: app} do
      {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")
      assert html =~ "/users/log-in?callback_url="
    end

    test "reflects unsaved headline and subtitle without persisting them", %{
      conn: conn,
      app: app
    } do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-branding-form", %{
          "headline" => "Draft headline",
          "subtitle" => "draft subtitle"
        })
        |> render_change()

      assert html =~ "Draft headline"
      assert html =~ "draft subtitle"

      # Preview only — nothing written until the form is submitted.
      assert Admin.get_app!(app.id).headline == nil
      assert Admin.get_app!(app.id).subtitle == nil
    end

    test "an over-long headline is dropped from the preview, mirroring the changeset cap", %{
      conn: conn,
      app: app
    } do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      too_long = String.duplicate("a", 201)

      html =
        lv
        |> form("#app-branding-form", %{"headline" => too_long, "subtitle" => ""})
        |> render_change()

      refute html =~ too_long
      # Falls back to the default copy instead of showing the rejected draft.
      assert html =~ "Sign in to continue to"
      assert Admin.get_app!(app.id).headline == nil
    end
  end

  describe "preview theme toggle" do
    test "toggling flips the dark class on the preview container only", %{conn: conn, app: app} do
      {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      assert html =~ ~s(phx-click="toggle_preview_theme")

      refute html =~
               ~s(class="mt-2 rounded-lg border border-border bg-background bg-cover bg-center px-5 py-8 text-center dark")

      html = render_click(lv, "toggle_preview_theme", %{})

      assert html =~
               ~s(class="mt-2 rounded-lg border border-border bg-background bg-cover bg-center px-5 py-8 text-center dark")

      # Toggling the preview theme must not flip the console's own document-wide theme.
      refute html =~ ~s(<html class="dark")
      refute html =~ ~s(<body class="dark")

      html = render_click(lv, "toggle_preview_theme", %{})

      refute html =~
               ~s(class="mt-2 rounded-lg border border-border bg-background bg-cover bg-center px-5 py-8 text-center dark")
    end
  end

  describe "theme configuration" do
    test "dark colour variants persist and fall back when unset", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      lv
      |> form("#app-branding-form", %{
        "brand_color" => "#7c3aed",
        "brand_color_dark" => "#a78bfa",
        "accent_color" => "#0ea5e9"
      })
      |> render_submit()

      saved = Admin.get_app!(app.id)
      assert saved.brand_color_dark == "#a78bfa"
      # Left blank, so the light value carries in dark mode.
      assert saved.accent_color_dark == nil
    end

    test "the preview renders both theme variants", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-branding-form", %{
          "brand_color" => "#7c3aed",
          "brand_color_dark" => "#a78bfa"
        })
        |> render_change()

      assert html =~ "color: #7c3aed"
      assert html =~ "color: #a78bfa"
    end

    test "an unset dark variant reuses the light colour in the dark span",
         %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-branding-form", %{"brand_color" => "#7c3aed", "brand_color_dark" => ""})
        |> render_change()

      # Both spans render, both using the light value.
      assert html =~ ~s(class="dark:hidden" style="color: #7c3aed")
      assert html =~ ~s(class="hidden dark:inline" style="color: #7c3aed")
    end

    test "an invalid dark colour is dropped from the preview", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-branding-form", %{
          "brand_color" => "#7c3aed",
          "brand_color_dark" => "red; background: url(https://attacker.example/x)"
        })
        |> render_change()

      refute html =~ "attacker.example"
    end

    test "theme mode saves", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html = lv |> form("#app-theme-form", %{"theme_mode" => "dark"}) |> render_submit()

      assert html =~ "Theme updated"
      assert Admin.get_app!(app.id).theme_mode == "dark"
    end

    test "theme mode rejects an unknown value", %{app: app} do
      assert {:error, changeset} = Admin.update_app(app, %{"theme_mode" => "sepia"})
      assert "is invalid" in errors_on(changeset).theme_mode
    end
  end

  describe "identity provider toggles" do
    setup do
      {:ok, provider} =
        You.IdentityProviders.create_provider(%{
          "slug" => "google",
          "display_name" => "Google",
          "kind" => "generic",
          "client_id" => "cid",
          "client_secret" => "sec",
          "authorize_url" => "https://accounts.example.com/auth",
          "token_url" => "https://accounts.example.com/token",
          "userinfo_url" => "https://accounts.example.com/me",
          "scopes" => "openid email",
          "enabled" => true
        })

      %{provider: provider}
    end

    test "all providers are ticked by default", %{conn: conn, app: app} do
      {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      assert html =~ ~s(phx-submit="update_providers")
      assert html =~ "Google"
    end

    test "unticking one stores the remaining subset", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-providers-form", %{
          "follow_instance" => "false",
          "providers" => %{"google" => "false"}
        })
        |> render_submit()

      assert html =~ "Identity providers updated"
      assert Admin.get_app!(app.id).enabled_providers == []
    end

    # "Follow the instance" is an explicit tick, not something inferred from
    # having every box ticked — so unticking and reticking a provider cannot
    # silently change what the record means.
    test "choosing to follow the instance stores nil", %{conn: conn, app: app} do
      {:ok, _app} = Admin.update_app(app, %{"enabled_providers" => []})

      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      lv
      |> form("#app-providers-form", %{
        "follow_instance" => "true",
        "providers" => %{"google" => "true"}
      })
      |> render_submit()

      assert Admin.get_app!(app.id).enabled_providers == nil
    end

    test "ticking every provider while restricting stores the explicit list",
         %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      lv
      |> form("#app-providers-form", %{
        "follow_instance" => "false",
        "providers" => %{"google" => "true"}
      })
      |> render_submit()

      assert Admin.get_app!(app.id).enabled_providers == ["google"]
    end
  end

  describe "background and accent" do
    test "previews unsaved values without persisting", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-branding-form", %{
          "accent_color" => "#0ea5e9",
          "background_image_url" => "https://cdn.example.com/bg.png"
        })
        |> render_change()

      assert html =~ "color: #0ea5e9"
      assert html =~ "background-image: url(https://cdn.example.com/bg.png)"

      assert Admin.get_app!(app.id).accent_color == nil
      assert Admin.get_app!(app.id).background_image_url == nil
    end

    # The preview never passes through App.changeset/2, so it needs its own
    # guards: HEEx escapes markup but not CSS-property or javascript: injection.
    test "the preview drops an invalid accent color and a javascript background",
         %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-branding-form", %{
          "accent_color" => "red; background: url(https://attacker.example/x)",
          "background_image_url" => "javascript:alert(1)"
        })
        |> render_change()

      refute html =~ "attacker.example"
      refute html =~ "javascript:alert"
    end

    test "saving persists both", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      lv
      |> form("#app-branding-form", %{
        "accent_color" => "#0ea5e9",
        "background_image_url" => "https://cdn.example.com/bg.png"
      })
      |> render_submit()

      saved = Admin.get_app!(app.id)
      assert saved.accent_color == "#0ea5e9"
      assert saved.background_image_url == "https://cdn.example.com/bg.png"
    end
  end

  describe "sign-in methods" do
    test "every method is ticked by default", %{conn: conn, app: app} do
      {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      assert html =~ ~s(phx-submit="update_methods")
      assert html =~ "Magic link"
    end

    test "unticking one stores the remaining subset", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      html =
        lv
        |> form("#app-methods-form", %{
          "follow_instance" => "false",
          "methods" => %{
            "password" => "true",
            "magic_link" => "false",
            "passkey" => "true",
            "social" => "false"
          }
        })
        |> render_submit()

      assert html =~ "Sign-in methods updated"
      assert Admin.get_app!(app.id).enabled_methods == ["password", "passkey"]
    end

    # nil is chosen, not inferred: a method added to You later reaches an app
    # that follows the instance, and reticking every box on a restricted app
    # does not silently convert it.
    test "choosing to follow the instance stores nil", %{conn: conn, app: app} do
      {:ok, _app} = Admin.update_app(app, %{"enabled_methods" => ["passkey"]})

      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      all = Map.new(You.Admin.App.auth_methods(), &{&1, "true"})

      lv
      |> form("#app-methods-form", %{"follow_instance" => "true", "methods" => all})
      |> render_submit()

      assert Admin.get_app!(app.id).enabled_methods == nil
    end

    test "ticking every method while restricting keeps the explicit list",
         %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=login")

      all = Map.new(You.Admin.App.auth_methods(), &{&1, "true"})

      lv
      |> form("#app-methods-form", %{"follow_instance" => "false", "methods" => all})
      |> render_submit()

      assert Admin.get_app!(app.id).enabled_methods == You.Admin.App.auth_methods()
    end
  end

  describe "roles" do
    test "adds a role to allowed_roles", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=roles")

      html = lv |> form("#app-add-role-form", %{"role" => "auditor"}) |> render_submit()

      assert html =~ "Role added"
      assert "auditor" in Admin.get_app!(app.id).allowed_roles
    end

    test "removes an unassigned role", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=roles")

      html = render_click(lv, "remove_role", %{"role" => "admin"})

      assert html =~ "Role removed"
      assert Admin.get_app!(app.id).allowed_roles == ["user"]
    end

    test "refuses to remove a role that is still assigned", %{conn: conn, app: app} do
      user = You.AccountsFixtures.user_fixture()
      {:ok, _} = Roles.set_role(app, user, "admin")

      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=roles")

      html = render_click(lv, "remove_role", %{"role" => "admin"})

      assert html =~ "Still assigned to users: admin"
      assert "admin" in Admin.get_app!(app.id).allowed_roles
    end

    test "shows the assignment count per role", %{conn: conn, app: app} do
      user = You.AccountsFixtures.user_fixture()
      {:ok, _} = Roles.set_role(app, user, "admin")

      {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.slug}?tab=roles")

      assert html =~ "1 user"
      assert html =~ "unassigned"
    end
  end

  describe "default role" do
    test "unassigned users resolve to the app default", %{app: app} do
      user = You.AccountsFixtures.user_fixture()
      assert Roles.role_for(app.slug, user.id) == "user"

      {:ok, _} = Admin.set_default_role(app, "admin")

      assert Roles.role_for(app.slug, user.id) == "admin"
    end

    test "an explicit assignment still wins over the default", %{app: app} do
      user = You.AccountsFixtures.user_fixture()
      {:ok, _} = Roles.set_role(app, user, "user")
      {:ok, _} = Admin.set_default_role(app, "admin")

      assert Roles.role_for(app.slug, user.id) == "user"
    end

    test "an unknown app still resolves to user", %{app: app} do
      {:ok, _} = Admin.set_default_role(app, "admin")
      assert Roles.role_for("no-such-app", 1) == "user"
    end

    test "the default must be one of the allowed roles", %{app: app} do
      assert {:error, changeset} = Admin.set_default_role(app, "wizard")
      assert "must be one of the allowed roles" in errors_on(changeset).default_role
    end

    test "a role that is the default cannot be dropped from allowed_roles", %{app: app} do
      {:ok, app} = Admin.set_default_role(app, "admin")

      assert {:error, changeset} = Admin.update_allowed_roles(app, ["user"])
      assert "must be one of the allowed roles" in errors_on(changeset).default_role
      assert "admin" in Admin.get_app!(app.id).allowed_roles
    end

    # The select renders a hidden input, which LiveViewTest treats as fixed, so
    # `form/3` cannot change it. Assert the wiring, then push the submit.
    test "changing it from the roles tab", %{conn: conn, app: app} do
      {:ok, lv, html} = live(conn, ~p"/console/apps/#{app.slug}?tab=roles")

      assert html =~ ~s(phx-submit="set_default_role")
      assert html =~ "data-confirm"

      assert render_submit(lv, "set_default_role", %{"default_role" => "admin"}) =~
               "Default role updated"

      assert Admin.get_app!(app.id).default_role == "admin"
    end
  end

  describe "bulk role assignment" do
    test "assigns one role to many users in a single statement", %{app: app} do
      users = for _ <- 1..3, do: You.AccountsFixtures.user_fixture()
      ids = Enum.map(users, & &1.id)

      assert {:ok, 3} = Roles.set_roles(app, ids, "admin")

      for user <- users, do: assert(Roles.role_for(app.slug, user.id) == "admin")
    end

    test "overwrites an existing assignment rather than failing", %{app: app} do
      user = You.AccountsFixtures.user_fixture()
      {:ok, _} = Roles.set_role(app, user, "user")

      assert {:ok, 1} = Roles.set_roles(app, [user.id], "admin")
      assert Roles.role_for(app.slug, user.id) == "admin"
    end

    test "rejects a role the app does not allow", %{app: app} do
      user = You.AccountsFixtures.user_fixture()
      assert {:error, :invalid_role} = Roles.set_roles(app, [user.id], "wizard")
    end

    test "selecting users then applying a role from the members tab", %{conn: conn, app: app} do
      user = You.AccountsFixtures.user_fixture()

      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=members")

      refute render(lv) =~ "1 selected"
      html = render_click(lv, "toggle_member", %{"user_id" => to_string(user.id)})
      assert html =~ "1 selected"

      # Assert the wiring, not only the handler: the action bar is a form, and
      # a missing phx-submit or data-confirm would not show up in a direct push.
      assert html =~ ~s(phx-submit="bulk_set_role")
      assert html =~ "data-confirm"

      html = render_submit(lv, "bulk_set_role", %{"role" => "admin"})

      assert html =~ "Updated 1 user"
      assert Roles.role_for(app.slug, user.id) == "admin"
      refute html =~ "1 selected"
    end

    test "rejects a selection carrying a non-numeric id", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=members")

      # A client can push any payload it likes over the socket.
      render_click(lv, "toggle_member", %{"user_id" => "not-an-id"})
      html = render_submit(lv, "bulk_set_role", %{"role" => "admin"})

      assert html =~ "no longer valid"
    end

    test "select-all toggles every row on and off", %{conn: conn, app: app} do
      for _ <- 1..2, do: You.AccountsFixtures.user_fixture()

      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=members")

      assert render_click(lv, "toggle_all_members", %{}) =~ "3 selected"
      refute render_click(lv, "toggle_all_members", %{}) =~ "3 selected"
    end
  end

  describe "members" do
    # The select is a JS hook, not a form input: it pushes `on_change` with
    # `params` merged in. Asserting the rendered wiring catches a mismatch that
    # pushing the event directly would hide.
    test "the row select is wired to set_member_role", %{conn: conn, app: app} do
      user = You.AccountsFixtures.user_fixture()

      {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.slug}?tab=members")

      assert html =~ ~s(data-on-change="set_member_role")
      assert html =~ ~s(data-params="{&quot;user_id&quot;:#{user.id}}")
    end

    test "assigns a role to a user", %{conn: conn, app: app} do
      user = You.AccountsFixtures.user_fixture()

      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=members")

      render_change(lv, "set_member_role", %{"user_id" => user.id, "value" => "admin"})

      assert Roles.role_for(app.slug, user.id) == "admin"
    end

    test "rejects a role the app does not allow", %{conn: conn, app: app} do
      user = You.AccountsFixtures.user_fixture()

      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=members")

      html = render_change(lv, "set_member_role", %{"user_id" => user.id, "value" => "wizard"})

      assert html =~ "Role is not allowed"
      assert Roles.role_for(app.slug, user.id) == "user"
    end
  end

  describe "credentials" do
    test "rotating the secret reveals it once", %{conn: conn, app: app} do
      {:ok, lv, _} = live(conn, ~p"/console/apps/#{app.slug}?tab=credentials")

      html = render_click(lv, "rotate_secret", %{})
      assert html =~ "Client secret"

      assert render_click(lv, "dismiss_secret", %{}) =~ "Rotate secret"
    end

    test "the OIDC snippet shows the discovery URL, client_id, and supported scopes", %{
      conn: conn,
      app: app
    } do
      {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.slug}?tab=credentials")

      assert html =~ "OIDC snippet"
      assert html =~ "#{YouWeb.Endpoint.url()}/.well-known/openid-configuration"
      assert html =~ "client_id: #{app.slug}"
      assert html =~ "scopes: email profile roles"
    end
  end
end
