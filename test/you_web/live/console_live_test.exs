defmodule YouWeb.ConsoleLiveTest do
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.{Admin, Accounts, Settings, IdentityProviders}

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)
    %{conn: log_in_user(conn, user), admin: user}
  end

  test "every view mounts", %{conn: conn} do
    for view <- ~w(overview users apps providers orgs audit webhooks settings) do
      {:ok, _lv, html} = live(conn, "/console?view=#{view}")
      assert html =~ "you"
    end
  end

  describe "feature toggles" do
    test "first admin login lands on the features screen", %{conn: conn} do
      refute You.Settings.get(:onboarding_completed)

      {:ok, _lv, html} = live(conn, ~p"/console")

      assert html =~ "Choose what this instance offers"
      assert html =~ ~s(phx-submit="save_features")
    end

    # Shown but locked, so an operator can see the feature exists rather than
    # wonder where it went.
    test "mandatory features are listed and disabled", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console?view=features")

      assert html =~ "Always on"
      assert html =~ "Password sign-in"
      assert html =~ "disabled"
    end

    test "saving stores the toggles and completes onboarding", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/console?view=features")

      html =
        lv
        |> form("#features-form", %{
          "features" => %{"feature_passkeys" => "true", "feature_magic_link" => "false"}
        })
        |> render_submit()

      assert html =~ "Features updated"
      assert You.Settings.get(:feature_passkeys) == true
      assert You.Settings.get(:feature_magic_link) == false
      assert You.Settings.get(:onboarding_completed) == true
    end

    test "after onboarding the console opens on the overview", %{conn: conn} do
      You.Settings.set(:onboarding_completed, true)

      {:ok, _lv, html} = live(conn, ~p"/console")

      refute html =~ "Choose what this instance offers"
    end
  end

  describe "apps" do
    test "create reveals a one-time secret; delete removes", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/console?view=apps")

      html =
        lv
        |> form("#new-app form", %{
          "name" => "Billing",
          "slug" => "billing",
          "callback_url" => "https://billing.example.com/cb"
        })
        |> render_submit()

      assert html =~ "Client secret"
      assert [app] = Admin.list_apps()

      # Through the rendered button, not a hand-built push: the binding and its
      # confirmation are part of what makes the delete safe.
      html = render(lv)
      assert html =~ ~s(phx-click="delete_app")
      assert html =~ "data-confirm"

      lv
      |> element(~s(button[phx-click="delete_app"][phx-value-id="#{app.id}"]))
      |> render_click()

      assert Admin.list_apps() == []
    end

    test "delete confirm surfaces real consent and role assignment counts", %{conn: conn} do
      {:ok, app, _secret} =
        Admin.create_app(%{
          "name" => "Blast Radius",
          "slug" => "blast-radius",
          "callback_url" => "https://blast-radius.example.com/cb"
        })

      user1 = You.AccountsFixtures.user_fixture()
      user2 = You.AccountsFixtures.user_fixture()
      user3 = You.AccountsFixtures.user_fixture()

      {:ok, _} = Accounts.record_consent(user1, app, ["profile"])
      {:ok, _} = Accounts.record_consent(user2, app, ["profile"])
      {:ok, _} = Accounts.record_consent(user3, app, ["profile"])

      {:ok, _} = You.Roles.set_role(app, user1, "admin")
      {:ok, _} = You.Roles.set_role(app, user2, "admin")

      {:ok, _lv, html} = live(conn, "/console?view=apps")

      assert html =~
               "permanently deletes 3 consents and 2 role assignments. This cannot be undone."
    end

    test "delete confirm uses singular wording for a count of one", %{conn: conn} do
      {:ok, app, _secret} =
        Admin.create_app(%{
          "name" => "Solo Impact",
          "slug" => "solo-impact",
          "callback_url" => "https://solo-impact.example.com/cb"
        })

      user = You.AccountsFixtures.user_fixture()
      {:ok, _} = Accounts.record_consent(user, app, ["profile"])
      {:ok, _} = You.Roles.set_role(app, user, "admin")

      {:ok, _lv, html} = live(conn, "/console?view=apps")

      assert html =~ "permanently deletes 1 consent and 1 role assignment. This cannot be undone."
    end

    test "delete confirm uses plural wording for zero counts", %{conn: conn} do
      {:ok, _app, _secret} =
        Admin.create_app(%{
          "name" => "No Impact",
          "slug" => "no-impact",
          "callback_url" => "https://no-impact.example.com/cb"
        })

      {:ok, _lv, html} = live(conn, "/console?view=apps")

      assert html =~
               "permanently deletes 0 consents and 0 role assignments. This cannot be undone."
    end

    test "create app with first_party true", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/console?view=apps")

      lv
      |> form("#new-app form", %{
        "name" => "Firsty",
        "slug" => "firsty",
        "callback_url" => "https://firsty.example.com/cb",
        "first_party" => "true"
      })
      |> render_submit()

      assert [app] = Admin.list_apps()
      assert app.first_party
    end
  end

  describe "provider setup guidance" do
    test "the new-provider dialog shows steps and the callback URL", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/console?view=providers")

      html = render_click(lv, "select_new_provider_preset", %{"value" => "github"})

      assert html =~ "Where to get these credentials for Github"
      assert html =~ "Developer settings"
      # The exact field to paste into, and the URL to paste.
      assert html =~ "Authorization callback URL"
      assert html =~ "/auth/github/callback"
      assert html =~ "docs.github.com"
    end

    test "guidance changes with the selected preset", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/console?view=providers")

      html = render_click(lv, "select_new_provider_preset", %{"value" => "slack"})
      assert html =~ "OAuth &amp; Permissions"
      refute html =~ "Developer settings"
    end

    # The generic preset has no vendor console to describe.
    test "the generic preset shows no guidance", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/console?view=providers")

      html = render_click(lv, "select_new_provider_preset", %{"value" => "generic"})
      refute html =~ "Where to get these credentials"
    end
  end

  describe "list search" do
    test "apps list filters by name and client id", %{conn: conn} do
      {:ok, _, _} =
        Admin.create_app(%{
          slug: "alpha",
          name: "Alpha",
          callback_url: "https://a.example.com/cb"
        })

      {:ok, _, _} =
        Admin.create_app(%{slug: "beta", name: "Beta", callback_url: "https://b.example.com/cb"})

      {:ok, lv, html} = live(conn, ~p"/console?view=apps")
      assert html =~ ~s(phx-change="filter_apps")

      html = render_change(lv, "filter_apps", %{"query" => "alph"})
      assert html =~ "Alpha"
      refute html =~ "Beta"

      # Matching the client id, not only the display name.
      html = render_change(lv, "filter_apps", %{"query" => "beta"})
      assert html =~ "Beta"
      refute html =~ "Alpha"
    end

    test "webhooks list has a search box", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console?view=webhooks")
      assert html =~ ~s(phx-change="filter_webhooks")
    end

    test "providers list has a search box", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console?view=providers")
      assert html =~ ~s(phx-change="filter_providers")
    end
  end

  describe "users" do
    test "change You role via the role dropdown", %{conn: conn} do
      other = You.AccountsFixtures.user_fixture()
      {:ok, lv, _} = live(conn, "/console?view=users")

      render_click(lv, "edit_user", %{"id" => other.id})
      render_click(lv, "set_you_role", %{"user_id" => other.id, "role" => "admin"})
      assert Accounts.get_user!(other.id).is_admin

      render_click(lv, "set_you_role", %{"user_id" => other.id, "role" => "user"})
      refute Accounts.get_user!(other.id).is_admin
    end

    test "admin cannot revoke their own admin rights", %{conn: conn, admin: admin} do
      {:ok, lv, _} = live(conn, "/console?view=users")

      render_click(lv, "edit_user", %{"id" => admin.id})
      render_click(lv, "set_you_role", %{"user_id" => admin.id, "role" => "user"})
      assert Accounts.get_user!(admin.id).is_admin
    end

    test "logout revokes sessions and anonymize wipes the account", %{conn: conn} do
      other = You.AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(other)
      {:ok, lv, _} = live(conn, "/console?view=users")

      render_click(lv, "logout_user", %{"id" => other.id})
      assert Accounts.get_user_by_session_token(token) == nil

      render_click(lv, "anonymize_user", %{"id" => other.id})
      refute Accounts.get_user!(other.id).email == other.email
    end

    test "filters narrow the user list", %{conn: conn} do
      You.AccountsFixtures.user_fixture(%{email: "findme@example.com"})
      {:ok, lv, _} = live(conn, "/console?view=users")

      html = render_change(lv, "filter_users", %{"email" => "findme"})
      assert html =~ "findme@example.com"

      html = render_change(lv, "filter_users", %{"email" => "no-such-user"})
      refute html =~ "findme@example.com"

      render_change(lv, "filter_users", %{"email" => ""})

      html = render_click(lv, "filter_users", %{"filter_key" => "status", "value" => "confirmed"})
      assert html =~ "findme@example.com"

      html =
        render_click(lv, "filter_users", %{"filter_key" => "status", "value" => "unconfirmed"})

      refute html =~ "findme@example.com"
    end

    test "app and role filters compose", %{conn: conn, admin: admin} do
      {:ok, app, _secret} =
        Admin.create_app(%{
          "name" => "Combo App",
          "slug" => "combo-app",
          "callback_url" => "https://combo.example.com/cb"
        })

      other = You.AccountsFixtures.user_fixture()
      {:ok, _} = You.Roles.set_role(app, admin, "admin")
      {:ok, lv, _} = live(conn, "/console?view=users")

      render_click(lv, "filter_users", %{"filter_key" => "app", "value" => to_string(app.id)})
      html = render_click(lv, "filter_users", %{"filter_key" => "role", "value" => "admin"})

      assert html =~ admin.email
      refute html =~ other.email
    end
  end

  describe "app roles" do
    test "assign a per-app role from the users view", %{conn: conn} do
      {:ok, app, _secret} =
        Admin.create_app(%{
          "name" => "Role App",
          "slug" => "role-app",
          "callback_url" => "https://role-app.example.com/cb"
        })

      other = You.AccountsFixtures.user_fixture()
      {:ok, lv, _} = live(conn, "/console?view=users")

      render_click(lv, "edit_user", %{"id" => other.id})

      render_click(lv, "save_app_role", %{
        "app_id" => app.id,
        "user_id" => other.id,
        "role" => "admin"
      })

      assert You.Roles.role_for(app.slug, other.id) == "admin"
    end
  end

  describe "audit" do
    test "filter narrows events by name and details", %{conn: conn} do
      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "probe",
        target: "needle-xyz"
      })

      _ = :sys.get_state(You.Audit.Streamer)
      {:ok, lv, _} = live(conn, "/console?view=audit")
      assert render(lv) =~ "needle-xyz"

      assert render_change(lv, "filter_audit", %{"filter" => "needle"}) =~ "needle-xyz"
      refute render_change(lv, "filter_audit", %{"filter" => "no-such-event"}) =~ "needle-xyz"
    end

    test "app select is wired to filter_audit_app", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/console?view=audit")

      assert html =~ ~s(id="filter-audit-app")
      assert html =~ ~s(data-on-change="filter_audit_app")
    end

    test "app filter narrows events to that app and resetting shows everything again", %{
      conn: conn
    } do
      {:ok, app_a, _secret} =
        Admin.create_app(%{
          "name" => "Audit App A",
          "slug" => "audit-app-a",
          "callback_url" => "https://audit-app-a.example.com/cb"
        })

      {:ok, _app_b, _secret} =
        Admin.create_app(%{
          "name" => "Audit App B",
          "slug" => "audit-app-b",
          "callback_url" => "https://audit-app-b.example.com/cb"
        })

      # app-scoped events, one per app
      {:ok, _} = Admin.update_app(app_a, %{"name" => "Audit App A Renamed"})

      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "update_app",
        app_slug: "audit-app-b"
      })

      # event with no app_slug at all in its metadata
      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "promote_admin",
        target_user_id: 999,
        target_email: "noone@example.com"
      })

      _ = :sys.get_state(You.Audit.Streamer)
      {:ok, lv, html} = live(conn, "/console?view=audit")

      # sanity: all three events show up unfiltered. Assertions below key on
      # `app_slug=&quot;...&quot;` (the metadata brief, HTML-escaped by HEEx)
      # rather than a bare slug, since the bare slug also appears as a
      # `data-value` on the (always fully populated) app select options —
      # matching on that would pass even if the filter did nothing.
      assert html =~ "action=&quot;update_app&quot;"
      assert html =~ "action=&quot;promote_admin&quot;"

      filtered_a =
        render_click(lv, "filter_audit_app", %{"value" => "audit-app-a"})

      assert filtered_a =~ "app_slug=&quot;audit-app-a&quot;"
      refute filtered_a =~ "app_slug=&quot;audit-app-b&quot;"
      refute filtered_a =~ "action=&quot;promote_admin&quot;"

      filtered_b =
        render_click(lv, "filter_audit_app", %{"value" => "audit-app-b"})

      assert filtered_b =~ "app_slug=&quot;audit-app-b&quot;"
      refute filtered_b =~ "app_slug=&quot;audit-app-a&quot;"
      refute filtered_b =~ "action=&quot;promote_admin&quot;"

      reset = render_click(lv, "filter_audit_app", %{"value" => ""})

      assert reset =~ "app_slug=&quot;audit-app-a&quot;"
      assert reset =~ "app_slug=&quot;audit-app-b&quot;"
      assert reset =~ "action=&quot;promote_admin&quot;"
    end

    # Role events predating the app_slug metadata carry the slug only in
    # `target`. The filter recovers it from there — but only for those actions,
    # so an unrelated event whose target happens to equal a slug stays out.
    test "the app filter catches legacy role events and nothing else", %{conn: conn} do
      {:ok, _app, _secret} =
        Admin.create_app(%{
          "name" => "Legacy",
          "slug" => "legacy-app",
          "callback_url" => "https://legacy-app.example.com/cb"
        })

      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "set_role",
        target: "legacy-app:someone@example.com",
        role: "admin"
      })

      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "set_roles",
        target: "legacy-app",
        role: "user"
      })

      # Same target string, unrelated action: must not be swept in.
      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "delete_webhook",
        target: "legacy-app"
      })

      _ = :sys.get_state(You.Audit.Streamer)
      {:ok, lv, _html} = live(conn, "/console?view=audit")

      filtered = render_click(lv, "filter_audit_app", %{"value" => "legacy-app"})

      assert filtered =~ "action=&quot;set_role&quot;"
      assert filtered =~ "action=&quot;set_roles&quot;"
      refute filtered =~ "action=&quot;delete_webhook&quot;"
    end
  end

  describe "settings" do
    test "saving persists SCIM token and audit webhook", %{conn: conn} do
      on_exit(fn -> Application.put_env(:you, :audit_webhook_url, "") end)
      {:ok, lv, _} = live(conn, "/console?view=settings")

      render_submit(form(lv, "form[phx-submit=save_settings]"), %{
        "scim_bearer_token" => "sekret",
        "audit_webhook_url" => "https://hooks.example.com/audit"
      })

      assert Settings.get(:scim_bearer_token) == "sekret"
      assert Settings.get(:audit_webhook_url) == "https://hooks.example.com/audit"
    end

    test "secrets are write-only: never rendered, blank keeps current, clear removes", %{
      conn: conn
    } do
      Settings.set(:erlang_cookie, "super-secret-cookie")
      on_exit(fn -> Settings.set(:erlang_cookie, "") end)

      {:ok, lv, _html} = live(conn, "/console?view=settings")

      refute render(lv) =~ "super-secret-cookie"

      render_submit(form(lv, "form[phx-submit=save_settings]"), %{
        "erlang_cookie" => "",
        "jwt_expiry_hours" => "24"
      })

      assert Settings.get(:erlang_cookie) == "super-secret-cookie"

      render_submit(form(lv, "form[phx-submit=save_settings]"), %{
        "erlang_cookie" => "new-cookie"
      })

      assert Settings.get(:erlang_cookie) == "new-cookie"

      render_click(lv, "clear_setting", %{"key" => "erlang_cookie"})
      assert Settings.get(:erlang_cookie) == ""
    end
  end

  describe "providers" do
    test "the nav links to the providers view", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/console?view=overview")
      assert html =~ ~s(href="/console?view=providers")
      assert html =~ "Providers"
    end

    test "create from a preset expands the preset's endpoints", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/console?view=providers")

      # Selecting the preset through the real select event first, matching how
      # a browser would: `form/3` refuses to override a hidden input to a
      # value the DOM doesn't already carry.
      render_click(lv, "select_new_provider_preset", %{"value" => "google"})

      html =
        lv
        |> form("#new-provider-form", %{
          "slug" => "google",
          "client_id" => "gid",
          "client_secret" => "gsecret"
        })
        |> render_submit()

      assert [provider] = IdentityProviders.list_providers()
      assert provider.slug == "google"
      assert provider.kind == "google"
      assert provider.display_name == "Google"
      assert provider.issuer == "https://accounts.google.com"
      assert provider.client_id == "gid"
      assert html =~ "google"
    end

    test "create a generic provider with hand-entered endpoints", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/console?view=providers")

      lv
      |> form("#new-provider-form", %{
        "preset" => "generic",
        "slug" => "okta",
        "display_name" => "Okta",
        "client_id" => "cid",
        "client_secret" => "csecret",
        "issuer" => "https://example.okta.com",
        "authorize_url" => "https://example.okta.com/authorize",
        "token_url" => "https://example.okta.com/token",
        "userinfo_url" => "https://example.okta.com/userinfo",
        "scopes" => "openid email profile"
      })
      |> render_submit()

      assert [provider] = IdentityProviders.list_providers()
      assert provider.slug == "okta"
      assert provider.kind == "generic"
      assert provider.issuer == "https://example.okta.com"
    end

    test "the preset select is wired to select_new_provider_preset", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/console?view=providers")

      assert html =~ ~s(id="new-provider-preset")
      assert html =~ ~s(data-on-change="select_new_provider_preset")
    end

    test "picking a named preset hides the endpoint fields the generic preset shows",
         %{conn: conn} do
      {:ok, lv, html} = live(conn, "/console?view=providers")
      # "generic" is the default preset, so the endpoint fields start visible.
      assert html =~ ~s(name="authorize_url")

      html = render_click(lv, "select_new_provider_preset", %{"value" => "google"})
      refute html =~ ~s(name="authorize_url")

      html = render_click(lv, "select_new_provider_preset", %{"value" => "generic"})
      assert html =~ ~s(name="authorize_url")
    end

    test "edit updates display name and endpoints", %{conn: conn} do
      {:ok, provider} =
        IdentityProviders.create_provider(%{
          "slug" => "okta",
          "display_name" => "Okta",
          "kind" => "generic",
          "client_id" => "cid",
          "client_secret" => "csecret"
        })

      {:ok, lv, _} = live(conn, "/console?view=providers")

      render_click(lv, "edit_provider", %{"id" => provider.id})

      lv
      |> form("#edit-provider-form", %{
        "display_name" => "Okta (renamed)",
        "client_id" => "new-cid",
        "issuer" => "https://renamed.okta.com"
      })
      |> render_submit()

      updated = IdentityProviders.get_provider!(provider.id)
      assert updated.display_name == "Okta (renamed)"
      assert updated.client_id == "new-cid"
      assert updated.issuer == "https://renamed.okta.com"
    end

    test "the edit sheet is wired to open on edit_provider and close on cancel_edit_provider", %{
      conn: conn
    } do
      {:ok, provider} =
        IdentityProviders.create_provider(%{
          "slug" => "okta",
          "display_name" => "Okta",
          "kind" => "generic"
        })

      {:ok, lv, html} = live(conn, "/console?view=providers")
      refute html =~ ~s(id="edit-provider-form")

      html = render_click(lv, "edit_provider", %{"id" => provider.id})
      assert html =~ ~s(id="edit-provider-form")
      assert html =~ ~s(phx-submit="update_provider")

      html = render_click(lv, "cancel_edit_provider", %{})
      refute html =~ ~s(id="edit-provider-form")
    end

    test "the client secret never appears in rendered HTML, and a blank secret on save preserves the stored one",
         %{conn: conn} do
      {:ok, provider} =
        IdentityProviders.create_provider(%{
          "slug" => "okta",
          "display_name" => "Okta",
          "kind" => "generic",
          "client_id" => "cid",
          "client_secret" => "super-secret-value"
        })

      {:ok, lv, html} = live(conn, "/console?view=providers")
      refute html =~ "super-secret-value"

      html = render_click(lv, "edit_provider", %{"id" => provider.id})
      refute html =~ "super-secret-value"

      lv
      |> form("#edit-provider-form", %{
        "display_name" => "Okta",
        "client_secret" => ""
      })
      |> render_submit()

      updated = IdentityProviders.get_provider!(provider.id)
      assert IdentityProviders.decrypt_secret(updated) == "super-secret-value"

      # Saving closes the edit sheet, so it has to be reopened before the form
      # can be found again for the second submission.
      render_click(lv, "edit_provider", %{"id" => provider.id})

      lv
      |> form("#edit-provider-form", %{
        "display_name" => "Okta",
        "client_secret" => "rotated-secret"
      })
      |> render_submit()

      rotated = IdentityProviders.get_provider!(provider.id)
      assert IdentityProviders.decrypt_secret(rotated) == "rotated-secret"
    end

    test "toggling enabled is wired to a real switch control", %{conn: conn} do
      {:ok, provider} =
        IdentityProviders.create_provider(%{
          "slug" => "okta",
          "display_name" => "Okta",
          "kind" => "generic"
        })

      {:ok, lv, html} = live(conn, "/console?view=providers")
      assert html =~ ~s(phx-click="toggle_provider")
      assert html =~ ~s(phx-value-id="#{provider.id}")

      render_click(lv, "toggle_provider", %{"id" => provider.id})
      refute IdentityProviders.get_provider!(provider.id).enabled

      render_click(lv, "toggle_provider", %{"id" => provider.id})
      assert IdentityProviders.get_provider!(provider.id).enabled
    end

    test "delete is confirmed before it fires", %{conn: conn} do
      {:ok, provider} =
        IdentityProviders.create_provider(%{
          "slug" => "okta",
          "display_name" => "Okta",
          "kind" => "generic"
        })

      {:ok, lv, html} = live(conn, "/console?view=providers")

      # Confirm the same `<button>` carries `phx-click="delete_provider"`,
      # `phx-value-id`, and `data-confirm` together — not merely that each
      # string appears somewhere in the page.
      [_, button_markup] =
        Regex.run(~r/(<button[^>]*phx-click="delete_provider"[^>]*>)/, html)

      assert button_markup =~ ~s(phx-value-id="#{provider.id}")
      assert button_markup =~ "data-confirm="

      render_click(lv, "delete_provider", %{"id" => provider.id})
      assert IdentityProviders.list_providers() == []
    end

    test "discover autofills the generic form from the issuer", %{conn: conn} do
      port = 45_950

      plug = fn conn, _opts ->
        body =
          Jason.encode!(%{
            "issuer" => "https://idp.example.com",
            "authorization_endpoint" => "https://idp.example.com/authorize",
            "token_endpoint" => "https://idp.example.com/token",
            "userinfo_endpoint" => "https://idp.example.com/userinfo",
            "scopes_supported" => ["openid", "email"]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      server = start_supervised!({Bandit, plug: plug, port: port, ip: :loopback})
      on_exit(fn -> Process.unlink(server) end)

      {:ok, lv, _html} = live(conn, "/console?view=providers")
      render_click(lv, "select_new_provider_preset", %{"value" => "generic"})

      html =
        lv
        |> form("form[phx-submit=discover_provider]", %{"issuer" => "http://localhost:#{port}"})
        |> render_submit()

      assert html =~ "https://idp.example.com/authorize"
      assert html =~ "https://idp.example.com/token"
    end
  end
end
