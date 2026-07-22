defmodule YouWeb.AdminConsoleTest do
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.{Admin, Organizations, Accounts}

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)
    %{conn: log_in_user(conn, user), admin: user}
  end

  describe "pages render" do
    test "dashboard, users, apps, orgs, audit, settings all mount", %{conn: conn} do
      for path <- ~w(/console /console/users /console/apps /console/orgs /console/audit /console/settings) do
        {:ok, _lv, html} = live(conn, path)
        assert html =~ "You"
      end
    end
  end

  describe "apps (m2m)" do
    test "create app reveals a one-time secret and lists it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/console/apps")

      html =
        lv
        |> form("#new-app form", %{
          "name" => "Billing",
          "slug" => "billing",
          "callback_url" => "https://billing.example.com/cb"
        })
        |> render_submit()

      assert html =~ "Client secret"
      assert html =~ "billing"
      assert [app] = Admin.list_apps()
      assert app.slug == "billing"
      assert app.client_secret_hash
    end

    test "delete app removes it", %{conn: conn} do
      {:ok, app, _secret} =
        Admin.create_app(%{name: "X", slug: "x", callback_url: "https://x/cb"})

      {:ok, lv, _html} = live(conn, "/console/apps")
      render_click(lv, "delete_app", %{"id" => app.id})
      assert Admin.list_apps() == []
    end
  end

  describe "orgs" do
    test "create org, select it, add and remove a member", %{conn: conn} do
      member = You.AccountsFixtures.user_fixture()
      {:ok, lv, _html} = live(conn, "/console/orgs")

      render_submit(form(lv, "#new-org form", %{"name" => "Acme", "slug" => "acme"}))
      assert [org] = Organizations.list_organizations()

      render_click(lv, "select_org", %{"id" => org.id})
      html = render_submit(form(lv, "form[phx-submit=add_member]", %{"email" => member.email, "role" => "member"}))
      assert html =~ member.email
      assert [{^member, "member"}] = Organizations.list_members(org)

      render_click(lv, "remove_member", %{"user_id" => member.id})
      assert Organizations.list_members(org) == []
    end
  end

  describe "users" do
    test "promote and demote another user", %{conn: conn} do
      other = You.AccountsFixtures.user_fixture()
      {:ok, lv, _html} = live(conn, "/console/users")

      render_click(lv, "promote", %{"id" => other.id})
      assert Accounts.get_user!(other.id).is_admin

      render_click(lv, "demote", %{"id" => other.id})
      refute Accounts.get_user!(other.id).is_admin
    end
  end

  describe "settings" do
    test "saving persists SCIM token and audit webhook", %{conn: conn} do
      # reload/0 writes the URL into global Application env; reset it so it does
      # not leak into other async test files (which would then attempt POSTs).
      on_exit(fn -> Application.put_env(:you, :audit_webhook_url, "") end)

      {:ok, lv, _html} = live(conn, "/console/settings")

      render_submit(form(lv, "form[phx-submit=save]"), %{
        "scim_bearer_token" => "sekret",
        "audit_webhook_url" => "https://hooks.example.com/audit"
      })

      assert You.Settings.get(:scim_bearer_token) == "sekret"
      assert You.Settings.get(:audit_webhook_url) == "https://hooks.example.com/audit"
    end
  end
end
