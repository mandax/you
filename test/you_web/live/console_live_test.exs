defmodule YouWeb.ConsoleLiveTest do
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.{Admin, Accounts, Settings, IdentityProviders}

  setup %{conn: conn} do
    # The default state everywhere except the "feature toggles" describe
    # block below, which is what actually exercises onboarding incomplete
    # and resets this itself — everywhere else, `/console` redirecting to
    # `/console/features` on a fresh instance would just be noise.
    You.Settings.set(:onboarding_completed, true)
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)
    %{conn: log_in_user(conn, user), admin: user}
  end

  test "every view mounts", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/console")
    assert html =~ "you"

    for view <- ~w(users apps providers audit webhooks settings) do
      {:ok, _lv, html} = live(conn, "/console/#{view}")
      assert html =~ "you"
    end
  end

  describe "feature toggles" do
    setup do
      You.Settings.set(:onboarding_completed, false)
      :ok
    end

    test "first admin login lands on the features screen", %{conn: conn} do
      refute You.Settings.get(:onboarding_completed)

      {:ok, conn} = live(conn, ~p"/console") |> follow_redirect(conn)

      assert html_response(conn, 200) =~ "Choose what this instance offers"
      assert html_response(conn, 200) =~ ~s(phx-submit="save_features")
    end

    # Shown but locked, so an operator can see the feature exists rather than
    # wonder where it went.
    test "mandatory features are listed and disabled", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console/features")

      assert html =~ "Always on"
      assert html =~ "Password sign-in"
      assert html =~ "disabled"
    end

    test "saving stores the toggles and completes onboarding", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/console/features")

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
      {:ok, lv, _} = live(conn, "/console/apps")

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

      {:ok, _lv, html} = live(conn, "/console/apps")

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

      {:ok, _lv, html} = live(conn, "/console/apps")

      assert html =~ "permanently deletes 1 consent and 1 role assignment. This cannot be undone."
    end

    test "delete confirm uses plural wording for zero counts", %{conn: conn} do
      {:ok, _app, _secret} =
        Admin.create_app(%{
          "name" => "No Impact",
          "slug" => "no-impact",
          "callback_url" => "https://no-impact.example.com/cb"
        })

      {:ok, _lv, html} = live(conn, "/console/apps")

      assert html =~
               "permanently deletes 0 consents and 0 role assignments. This cannot be undone."
    end

    test "create app with first_party true", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/console/apps")

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
      {:ok, lv, _} = live(conn, ~p"/console/providers")

      html = render_click(lv, "select_new_provider_preset", %{"value" => "github"})

      assert html =~ "Where to get these credentials for Github"
      assert html =~ "Developer settings"
      # The exact field to paste into, and the URL to paste.
      assert html =~ "Authorization callback URL"
      assert html =~ "/auth/github/callback"
      assert html =~ "docs.github.com"
    end

    test "guidance changes with the selected preset", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/console/providers")

      html = render_click(lv, "select_new_provider_preset", %{"value" => "slack"})
      assert html =~ "OAuth &amp; Permissions"
      refute html =~ "Developer settings"
    end

    # The generic preset has no vendor console to describe.
    test "the generic preset shows no guidance", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/console/providers")

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

      {:ok, lv, html} = live(conn, ~p"/console/apps")
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
      {:ok, _lv, html} = live(conn, ~p"/console/webhooks")
      assert html =~ ~s(phx-change="filter_webhooks")
    end

    test "providers list has a search box", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console/providers")
      assert html =~ ~s(phx-change="filter_providers")
    end
  end

  describe "users" do
    test "change You role via the role dropdown", %{conn: conn} do
      other = You.AccountsFixtures.user_fixture()
      {:ok, lv, _} = live(conn, "/console/users")

      render_click(lv, "edit_user", %{"id" => other.id})
      render_click(lv, "set_you_role", %{"user_id" => other.id, "role" => "admin"})
      assert Accounts.get_user!(other.id).is_admin

      render_click(lv, "set_you_role", %{"user_id" => other.id, "role" => "user"})
      refute Accounts.get_user!(other.id).is_admin
    end

    test "admin cannot revoke their own admin rights", %{conn: conn, admin: admin} do
      {:ok, lv, _} = live(conn, "/console/users")

      render_click(lv, "edit_user", %{"id" => admin.id})
      render_click(lv, "set_you_role", %{"user_id" => admin.id, "role" => "user"})
      assert Accounts.get_user!(admin.id).is_admin
    end

    test "logout revokes sessions and anonymize wipes the account", %{conn: conn} do
      other = You.AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(other)
      {:ok, lv, _} = live(conn, "/console/users")

      render_click(lv, "logout_user", %{"id" => other.id})
      assert Accounts.get_user_by_session_token(token) == nil

      render_click(lv, "anonymize_user", %{"id" => other.id})
      refute Accounts.get_user!(other.id).email == other.email
    end

    test "reset_2fa clears TOTP, wipes recovery codes, revokes sessions, and is audited", %{
      conn: conn
    } do
      other = You.AccountsFixtures.user_fixture()
      {:ok, %{secret: secret}} = Accounts.generate_totp_setup(other)
      other = Accounts.get_user!(other.id)

      {:ok, %{recovery_codes: old_codes}} =
        Accounts.enable_totp(other, NimbleTOTP.verification_code(secret))

      other = Accounts.get_user!(other.id)
      assert other.totp_enabled
      assert Accounts.count_unused_recovery_codes(other) == 8

      session_token = Accounts.generate_user_session_token(other)

      :telemetry.attach(
        "test-reset-2fa-audit",
        [:you, :audit, :admin, :action],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:audit, metadata})
        end,
        self()
      )

      {:ok, lv, _} = live(conn, "/console/users")
      render_click(lv, "edit_user", %{"id" => other.id})
      html = render_click(lv, "reset_2fa", %{"id" => other.id})

      assert html =~ "Two-factor authentication reset"

      reset_user = Accounts.get_user!(other.id)
      refute reset_user.totp_enabled
      assert reset_user.totp_secret == nil
      assert Accounts.count_unused_recovery_codes(reset_user) == 0
      assert Accounts.get_user_by_session_token(session_token) == nil

      for code <- old_codes do
        assert {:error, :invalid_code} = Accounts.verify_recovery_code(reset_user, code)
      end

      assert_receive {:audit, %{action: "reset_2fa", target: email}}
      assert email == other.email

      :telemetry.detach("test-reset-2fa-audit")
    end

    test "a user can re-enroll TOTP after an admin reset", %{conn: conn} do
      other = You.AccountsFixtures.user_fixture()
      {:ok, %{secret: secret}} = Accounts.generate_totp_setup(other)
      other = Accounts.get_user!(other.id)
      {:ok, _} = Accounts.enable_totp(other, NimbleTOTP.verification_code(secret))
      other = Accounts.get_user!(other.id)

      {:ok, lv, _} = live(conn, "/console/users")
      render_click(lv, "edit_user", %{"id" => other.id})
      render_click(lv, "reset_2fa", %{"id" => other.id})

      reset_user = Accounts.get_user!(other.id)
      refute reset_user.totp_enabled

      {:ok, %{secret: new_secret}} = Accounts.generate_totp_setup(reset_user)
      reset_user = Accounts.get_user!(reset_user.id)

      assert {:ok, %{totp_enabled: true, recovery_codes: new_codes}} =
               Accounts.enable_totp(reset_user, NimbleTOTP.verification_code(new_secret))

      assert length(new_codes) == 8
      final_user = Accounts.get_user!(reset_user.id)
      assert final_user.totp_enabled
      assert Accounts.count_unused_recovery_codes(final_user) == 8
    end

    test "filters narrow the user list", %{conn: conn} do
      You.AccountsFixtures.user_fixture(%{email: "findme@example.com"})
      {:ok, lv, _} = live(conn, "/console/users")

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
      {:ok, lv, _} = live(conn, "/console/users")

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
      {:ok, lv, _} = live(conn, "/console/users")

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
      {:ok, lv, _} = live(conn, "/console/audit")
      assert render(lv) =~ "needle-xyz"

      assert render_change(lv, "filter_audit", %{"filter" => "needle"}) =~ "needle-xyz"
      refute render_change(lv, "filter_audit", %{"filter" => "no-such-event"}) =~ "needle-xyz"
    end

    test "app select is wired to filter_audit_app", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/console/audit")

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
      {:ok, lv, html} = live(conn, "/console/audit")

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
      {:ok, lv, _html} = live(conn, "/console/audit")

      filtered = render_click(lv, "filter_audit_app", %{"value" => "legacy-app"})

      assert filtered =~ "action=&quot;set_role&quot;"
      assert filtered =~ "action=&quot;set_roles&quot;"
      refute filtered =~ "action=&quot;delete_webhook&quot;"
    end
  end

  describe "settings" do
    test "renders as tabs, defaulting to the first", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/console/settings")

      assert html =~ ~s(role="tablist")
      assert html =~ "Session &amp; tokens"
      assert html =~ ~s(href="/console/settings/mail")
      # Asserted as independent attributes rather than one contiguous string:
      # attribute order is not part of the contract, and pinning it makes an
      # unrelated addition look like a regression.
      assert html =~ ~s(id="tabpanel-session")
      assert html =~ ~s(role="tabpanel")
      assert html =~ ~s(aria-labelledby="tab-session")
      refute html =~ "SMTP host"
    end

    test "the tab path segment selects the matching tab", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/console/settings/mail")

      assert html =~ "SMTP host"
      refute html =~ "Session expiry"
    end

    test "an unknown tab falls back to the first tab rather than blanking", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/console/settings/bogus")

      assert html =~ "Session expiry"
      assert html =~ ~r/id="tab-session"[^>]*aria-selected="true"/
    end

    # Federation is the one tab whose contract is "renders no form". That is
    # exactly what a refactor of the hoisted wrapper would break, and what a
    # reviewer misread as already broken.
    test "the Federation tab renders reference material and no form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/console/settings/federation")

      refute html =~ "Save settings"
      refute html =~ "save_settings"
      assert html =~ "openid-configuration"
    end

    # Five fields changed tab in this consolidation. Naming each one here is
    # what stops one being dropped from the UI unnoticed, which would leave it
    # configurable only through the database.
    test "the Integrations tab carries every field that moved into it", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/console/settings/integrations")

      for name <- ~w(scim_bearer_token audit_webhook_url api_token analytics_src analytics_domain) do
        assert html =~ ~s(name="#{name}"), "#{name} is missing from the Integrations tab"
      end
    end

    test "saving persists SCIM token and audit webhook", %{conn: conn} do
      on_exit(fn -> Application.put_env(:you, :audit_webhook_url, "") end)
      {:ok, lv, _} = live(conn, "/console/settings/integrations")

      render_submit(form(lv, "form[phx-submit=save_settings]"), %{
        "scim_bearer_token" => "sekret",
        "audit_webhook_url" => "https://hooks.example.com/audit"
      })

      assert Settings.get(:scim_bearer_token) == "sekret"
      assert Settings.get(:audit_webhook_url) == "https://hooks.example.com/audit"
    end

    test "flipping deployment mode reshapes the console for this session", %{conn: conn} do
      {:ok, _app, _secret} =
        Admin.create_app(%{
          slug: "solo",
          name: "Solo",
          callback_url: "https://solo.example.com/cb"
        })

      {:ok, lv, html} = live(conn, "/console/settings/deployment")
      refute html =~ ~s(href="/console/apps/solo")

      render_submit(form(lv, "form[phx-submit=save_settings]"), %{"you_mode" => "single"})

      assert You.Mode.single?()
      assert render(lv) =~ ~s(href="/console/apps/solo")
    end

    test "secrets are write-only: never rendered, blank keeps current, clear removes", %{
      conn: conn
    } do
      Settings.set(:erlang_cookie, "super-secret-cookie")
      on_exit(fn -> Settings.set(:erlang_cookie, "") end)

      {:ok, lv, _html} = live(conn, "/console/settings/distribution")

      refute render(lv) =~ "super-secret-cookie"

      render_submit(form(lv, "form[phx-submit=save_settings]"), %{"erlang_cookie" => ""})

      assert Settings.get(:erlang_cookie) == "super-secret-cookie"

      render_submit(form(lv, "form[phx-submit=save_settings]"), %{
        "erlang_cookie" => "new-cookie"
      })

      assert Settings.get(:erlang_cookie) == "new-cookie"

      render_click(lv, "clear_setting", %{"key" => "erlang_cookie"})
      assert Settings.get(:erlang_cookie) == ""
    end

    test "saving one tab leaves another tab's settings untouched", %{conn: conn} do
      Settings.set(:mail_from, "noreply@example.com")
      on_exit(fn -> Settings.set(:mail_from, "") end)

      {:ok, lv, _html} = live(conn, "/console/settings/session")

      render_submit(form(lv, "form[phx-submit=save_settings]"), %{
        "jwt_expiry_hours" => "48"
      })

      assert Settings.get(:jwt_expiry_hours) == 48
      assert Settings.get(:mail_from) == "noreply@example.com"
    end
  end

  describe "providers" do
    test "the nav links to the providers view", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/console")
      assert html =~ ~s(href="/console/providers")
      assert html =~ "Providers"
    end

    test "create from a preset expands the preset's endpoints", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/console/providers")

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
      {:ok, lv, _} = live(conn, "/console/providers")

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
      {:ok, _lv, html} = live(conn, "/console/providers")

      assert html =~ ~s(id="new-provider-preset")
      assert html =~ ~s(data-on-change="select_new_provider_preset")
    end

    test "picking a named preset hides the endpoint fields the generic preset shows",
         %{conn: conn} do
      {:ok, lv, html} = live(conn, "/console/providers")
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

      {:ok, lv, _} = live(conn, "/console/providers")

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

      {:ok, lv, html} = live(conn, "/console/providers")
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

      {:ok, lv, html} = live(conn, "/console/providers")
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

      {:ok, lv, html} = live(conn, "/console/providers")
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

      {:ok, lv, html} = live(conn, "/console/providers")

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

      {:ok, lv, _html} = live(conn, "/console/providers")
      render_click(lv, "select_new_provider_preset", %{"value" => "generic"})

      html =
        lv
        |> form("form[phx-submit=discover_provider]", %{"issuer" => "http://localhost:#{port}"})
        |> render_submit()

      assert html =~ "https://idp.example.com/authorize"
      assert html =~ "https://idp.example.com/token"
    end
  end

  describe "per-section data loading" do
    test "overview renders live counts rather than cached rows", %{conn: conn} do
      You.Settings.set(:onboarding_completed, true)
      You.AccountsFixtures.user_fixture()
      extra_admin = You.AccountsFixtures.user_fixture()
      Admin.promote_admin!(extra_admin)

      {:ok, _lv, html} = live(conn, "/console")

      assert metric_value(html, "Users") == Admin.count_users()
      assert metric_value(html, "Admins") == Admin.count_admins()
    end

    test "patching to another view loads that view's data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/console/audit")

      html = lv |> element("a", "add a webhook for durable retention") |> render_click()

      assert html =~ "Add endpoint"
    end

    test "logout_user reloads only the user list, not the app list also shown on that view", %{
      conn: conn
    } do
      other = You.AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(other)
      {:ok, lv, _html} = live(conn, "/console/users")

      {:ok, _app, _secret} =
        Admin.create_app(%{
          "name" => "Side App",
          "slug" => "side-app",
          "callback_url" => "https://side.example.com/cb"
        })

      html = render_click(lv, "logout_user", %{"id" => other.id})

      assert Accounts.get_user_by_session_token(token) == nil
      refute html =~ "Side App"
    end

    test "the 5s tick reloads the audit feed only on the overview and audit views", %{
      conn: conn
    } do
      You.Settings.set(:onboarding_completed, true)
      {:ok, lv, _html} = live(conn, "/console")

      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "probe",
        target: "tick-event"
      })

      _ = :sys.get_state(You.Audit.Streamer)
      refute render(lv) =~ "tick-event"

      send(lv.pid, :refresh)
      assert render(lv) =~ "tick-event"
    end

    test "the 5s tick does not re-query users, apps, or providers on other views", %{
      conn: conn
    } do
      {:ok, lv, html} = live(conn, "/console/apps")
      refute html =~ "Ghost App"

      {:ok, _app, _secret} =
        Admin.create_app(%{
          "name" => "Ghost App",
          "slug" => "ghost-app",
          "callback_url" => "https://ghost.example.com/cb"
        })

      send(lv.pid, :refresh)
      refute render(lv) =~ "Ghost App"
    end
  end

  describe "path-based sections (#136)" do
    # `render_patch/2` alone doesn't prove this: it succeeds against *any*
    # route the router can resolve, including one belonging to a different
    # LiveView, so it cannot tell a same-process patch from a silent
    # remount. Clicking the real sidebar link is the only way to exercise
    # what the browser actually does — `data-phx-link="patch"` is what
    # keeps the client from doing a full navigation, and the unchanged pid
    # is the proof the server side didn't remount either.
    test "clicking a sidebar section link patches rather than remounts", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/console/users")
      pid = lv.pid

      link = element(lv, "nav a[href='/console/settings']")
      assert render(link) =~ ~s(data-phx-link="patch")

      html = render_click(link)

      assert lv.pid == pid
      assert html =~ "Session &amp; tokens"
    end

    # The single-app nav entry (`YouWeb.Components.ConsoleChrome.apps_entry/1`)
    # points at `AppLive.Show`, a different module — patch cannot cross
    # modules, so this one link keeps `navigate=`.
    test "the single-app nav entry navigates rather than patches", %{conn: conn} do
      {:ok, _app, _secret} =
        Admin.create_app(%{
          slug: "solo",
          name: "Solo",
          callback_url: "https://solo.example.com/cb"
        })

      You.Settings.set(:you_mode, "single")

      Application.put_env(:you, :single_app,
        slug: "solo",
        callback_url: "https://solo.example.com/cb"
      )

      on_exit(fn -> Application.delete_env(:you, :single_app) end)

      {:ok, _lv, html} = live(conn, ~p"/console")

      assert html =~ ~s(href="/console/apps/solo" data-phx-link="redirect")
    end

    test "the old ?view=x&tab=y query form redirects to the path equivalent", %{conn: conn} do
      conn = get(conn, "/console?view=settings&tab=mail")

      assert redirected_to(conn) == "/console/settings/mail"
    end

    test "the old ?view=x query form redirects to the view's path", %{conn: conn} do
      conn = get(conn, "/console?view=users")

      assert redirected_to(conn) == "/console/users"
    end

    test "a trailing slash on the old query form still redirects", %{conn: conn} do
      conn = get(conn, "/console/?view=settings")

      assert redirected_to(conn) == "/console/settings"
    end

    test "the old /console/apps/:slug?tab=x form redirects to the path equivalent", %{
      conn: conn
    } do
      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "edit-me",
          name: "Edit Me",
          callback_url: "https://e.example.com/cb"
        })

      conn = get(conn, "/console/apps/#{app.slug}?tab=members")

      assert redirected_to(conn) == "/console/apps/#{app.slug}/members"
    end

    # A crawler or a hand-edited bookmark can produce this shape
    # (`?view[a]=b` decodes to a map, not a string) — it must be ignored by
    # the redirect and 404 on its own terms, never crash the request.
    test "a bracketed query param does not crash the legacy redirect", %{conn: conn} do
      assert_raise YouWeb.NotFoundError, fn -> live(conn, "/console?view[a]=b") end
    end

    test "an unknown section 404s instead of rendering the overview", %{conn: conn} do
      assert_raise YouWeb.NotFoundError, fn -> live(conn, ~p"/console/not-a-section") end
    end

    test "an unknown tab within a real section still falls back rather than 404ing", %{
      conn: conn
    } do
      {:ok, _lv, html} = live(conn, ~p"/console/settings/not-a-tab")

      assert html =~ "Session &amp; tokens"
    end

    # Overview is a section like any other — reachable at its own path
    # regardless of onboarding state. Only the bare `/console` (no explicit
    # view) substitutes a different default while onboarding is incomplete.
    test "overview is reachable at its own path during onboarding", %{conn: conn} do
      You.Settings.set(:onboarding_completed, false)

      {:ok, _lv, html} = live(conn, ~p"/console/overview")

      assert html =~ "Instance at a glance"
    end

    test "the bare /console redirects to features while onboarding is incomplete", %{
      conn: conn
    } do
      You.Settings.set(:onboarding_completed, false)

      conn = get(conn, "/console")

      assert redirected_to(conn) == "/console/features"
    end

    test "the bare /console renders overview once onboarding is complete", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console")

      assert html =~ "Instance at a glance"
    end
  end

  describe "state hygiene across a patch (review round 2)" do
    # On `main`, every section switch was a `navigate` and so remounted —
    # `nav` and every "shown once" assign came back from `mount/3` for free.
    # Patch keeps the process alive, so anything that used to reset itself
    # by virtue of remounting now needs to say so explicitly.

    test "switching a feature off refreshes the sidebar in the same process", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/console/features")
      assert html =~ ~s(href="/console/webhooks")

      html =
        lv
        |> form("#features-form", %{"features" => %{"feature_webhooks" => "false"}})
        |> render_submit()

      refute html =~ ~s(href="/console/webhooks")
    end

    test "a one-time secret dialog closes on a section change but survives a tab change", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/console/webhooks")

      html =
        render_submit(lv, "create_webhook", %{
          "url" => "https://hook.example.com/notify",
          "events" => %{"login:attempt" => "true"}
        })

      assert html =~ ~s(id="copy-webhook-secret")

      # Same section, different tab param (webhooks has no tabs of its own,
      # but the route still carries one) — must not clear it.
      html = render_patch(lv, ~p"/console/webhooks/anything")
      assert html =~ ~s(id="copy-webhook-secret")

      # A real section change does.
      html = lv |> element("nav a[href='/console/apps']") |> render_click()
      refute html =~ ~s(id="copy-webhook-secret")
    end

    test "Settings' Federation tab shows a provider created after connecting", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/console/settings/federation")
      refute html =~ "fresh-provider"

      {:ok, _provider} =
        IdentityProviders.create_provider(%{
          "slug" => "fresh-provider",
          "display_name" => "Fresh",
          "kind" => "generic",
          "client_id" => "cid",
          "client_secret" => "csecret"
        })

      html = render_patch(lv, ~p"/console/settings/federation")

      assert html =~ "fresh-provider"
    end
  end

  defp metric_value(html, label) do
    [_, value] =
      Regex.run(
        ~r/#{Regex.escape(label)}<\/div>\s*<div[^>]*>\s*<span[^>]*>\s*(\d+)\s*</,
        html
      )

    String.to_integer(value)
  end
end
