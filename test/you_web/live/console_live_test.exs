defmodule YouWeb.ConsoleLiveTest do
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.{Admin, Organizations, Accounts, Settings}

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)
    %{conn: log_in_user(conn, user), admin: user}
  end

  test "every view mounts", %{conn: conn} do
    for view <- ~w(overview users apps orgs audit settings) do
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

    test "edit app changes name and toggles first_party", %{conn: conn} do
      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "edit-me",
          name: "Edit Me",
          callback_url: "https://edit.example.com/cb"
        })

      refute app.first_party

      {:ok, lv, _} = live(conn, "/console?view=apps")

      # Open the edit dialog
      render_click(lv, "edit_app", %{"id" => app.id})

      # Submit the edit form
      html =
        lv
        |> form("#edit-app form", %{
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

    test "create and edit app with login branding", %{conn: conn} do
      {:ok, lv, _} = live(conn, "/console?view=apps")

      lv
      |> form("#new-app form", %{
        "name" => "Branded",
        "slug" => "branded",
        "callback_url" => "https://branded.example.com/cb",
        "logo_url" => "https://branded.example.com/logo.png",
        "brand_color" => "#7c3aed"
      })
      |> render_submit()

      assert [app] = Admin.list_apps()
      assert app.logo_url == "https://branded.example.com/logo.png"
      assert app.brand_color == "#7c3aed"

      render_click(lv, "edit_app", %{"id" => app.id})

      html =
        lv
        |> form("#edit-app form", %{
          "name" => "Branded",
          "callback_url" => "https://branded.example.com/cb",
          "logo_url" => "",
          "brand_color" => "#0ea5e9"
        })
        |> render_submit()

      assert html =~ "App updated"

      updated = Admin.get_app!(app.id)
      assert updated.logo_url == nil
      assert updated.brand_color == "#0ea5e9"
    end
  end

  describe "orgs" do
    test "create, select, add and remove a member", %{conn: conn} do
      member = You.AccountsFixtures.user_fixture()
      {:ok, lv, _} = live(conn, "/console?view=orgs")

      render_submit(form(lv, "#new-org form", %{"name" => "Acme", "slug" => "acme"}))
      assert [org] = Organizations.list_organizations()

      render_click(lv, "select_org", %{"id" => org.id})

      html =
        render_submit(
          form(lv, "form[phx-submit=add_member]", %{"email" => member.email, "role" => "member"})
        )

      assert html =~ member.email
      assert [{^member, "member"}] = Organizations.list_members(org)

      render_click(lv, "remove_member", %{"user_id" => member.id})
      assert Organizations.list_members(org) == []
    end
  end

  describe "users" do
    test "promote and demote another user", %{conn: conn} do
      other = You.AccountsFixtures.user_fixture()
      {:ok, lv, _} = live(conn, "/console?view=users")

      render_click(lv, "promote", %{"id" => other.id})
      assert Accounts.get_user!(other.id).is_admin

      render_click(lv, "demote", %{"id" => other.id})
      refute Accounts.get_user!(other.id).is_admin
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
