defmodule YouWeb.AppLive.ShowTest do
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

  describe "members" do
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
  end
end
