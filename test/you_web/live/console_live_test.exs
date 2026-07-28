defmodule YouWeb.ConsoleLiveTest do
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.{Admin, Accounts, Settings}

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)
    %{conn: log_in_user(conn, user), admin: user}
  end

  test "every view mounts", %{conn: conn} do
    for view <- ~w(overview users apps orgs audit webhooks settings) do
      {:ok, _lv, html} = live(conn, "/console?view=#{view}")
      assert html =~ "you"
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

      render_click(lv, "delete_app", %{"id" => app.id})
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
end
