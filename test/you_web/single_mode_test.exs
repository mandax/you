defmodule YouWeb.SingleModeTest do
  @moduledoc """
  What `YOU_MODE=single` changes across the web surface: no consent screen, no
  app grid on the account hub, no apps registry in the console.
  """
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.Accounts
  alias You.Admin

  @callback_url "https://solo.example.com/cb"

  setup do
    {:ok, app, _secret} =
      Admin.create_app(%{
        slug: "solo",
        name: "Solo",
        callback_url: @callback_url,
        launch_url: "https://solo.example.com"
      })

    %{app: app}
  end

  defp single_mode(_context) do
    You.Settings.set(:you_mode, "single")
    Application.put_env(:you, :single_app, slug: "solo", callback_url: @callback_url)

    on_exit(fn -> Application.delete_env(:you, :single_app) end)

    :ok
  end

  describe "consent screen" do
    setup [:register_and_log_in_user, :single_mode]

    test "is skipped for the first-party app regardless of mode", %{conn: conn, app: app} do
      {:ok, _app} = Admin.update_app(app, %{first_party: true})

      conn = get(conn, ~p"/users/log-in?callback_url=#{@callback_url}&scope=email")

      assert redirected_to(conn) =~ "#{@callback_url}?code="
    end

    test "still records consent for a first-party app, so flipping to multi mode leaves no gap",
         %{
           conn: conn,
           user: user,
           app: app
         } do
      {:ok, app} = Admin.update_app(app, %{first_party: true})

      get(conn, ~p"/users/log-in?callback_url=#{@callback_url}&scope=email")

      assert [consented] = Accounts.list_consented_apps(user)
      assert consented.id == app.id
    end

    test "echoes the consumer's state back on the redirect", %{conn: conn, app: app} do
      {:ok, _app} = Admin.update_app(app, %{first_party: true})

      conn = get(conn, ~p"/users/log-in?callback_url=#{@callback_url}&state=xyz")

      assert redirected_to(conn) =~ "state=xyz"
    end

    test "still shows for a third-party app, even in single-app mode", %{conn: conn} do
      html =
        conn
        |> get(~p"/users/log-in?callback_url=#{@callback_url}&scope=email")
        |> html_response(200)

      assert html =~ "Authorize"
    end
  end

  describe "consent screen in multi mode" do
    setup :register_and_log_in_user

    test "still asks a third-party app to authorize", %{conn: conn} do
      html =
        conn
        |> get(~p"/users/log-in?callback_url=#{@callback_url}&scope=email")
        |> html_response(200)

      assert html =~ "Authorize"
    end

    test "skips it for a first-party app, same as single-app mode", %{conn: conn, app: app} do
      {:ok, _app} = Admin.update_app(app, %{first_party: true})

      conn = get(conn, ~p"/users/log-in?callback_url=#{@callback_url}&scope=email")

      assert redirected_to(conn) =~ "#{@callback_url}?code="
    end

    test "still records consent for a first-party app in multi mode", %{
      conn: conn,
      user: user,
      app: app
    } do
      {:ok, app} = Admin.update_app(app, %{first_party: true})

      get(conn, ~p"/users/log-in?callback_url=#{@callback_url}&scope=email")

      assert [consented] = Accounts.list_consented_apps(user)
      assert consented.id == app.id
    end
  end

  describe "login page branding" do
    setup :single_mode

    test "the plain login page stays You's own", %{conn: conn, app: app} do
      {:ok, _} = Admin.update_app(app, %{"headline" => "Welcome back to Solo"})

      refute conn |> get(~p"/users/log-in") |> html_response(200) =~ "Welcome back to Solo"
    end

    test "?app= renders the app's page", %{conn: conn, app: app} do
      {:ok, _} = Admin.update_app(app, %{"headline" => "Welcome back to Solo"})

      assert conn |> get(~p"/users/log-in?app=solo") |> html_response(200) =~
               "Welcome back to Solo"
    end
  end

  describe "account hub" do
    setup [:register_and_log_in_user, :single_mode]

    test "goes straight to the account instead of an app grid", %{conn: conn} do
      conn = get(conn, ~p"/users/dashboard")

      assert redirected_to(conn) == ~p"/users/settings"
    end

    test "drops the apps entry from the account nav", %{conn: conn} do
      html = conn |> get(~p"/users/settings") |> html_response(200)

      refute html =~ "Your apps"
    end

    test "offers the way back into the app, at its configured launch URL", %{conn: conn} do
      html = conn |> get(~p"/users/settings") |> html_response(200)

      assert html =~ "Open Solo"
      assert html =~ ~s(href="https://solo.example.com")
    end

    test "falls back to the callback origin when no launch URL is configured", %{
      conn: conn,
      app: app
    } do
      {:ok, _} = Admin.update_app(app, %{"launch_url" => ""})

      html = conn |> get(~p"/users/settings") |> html_response(200)

      assert html =~ ~s(href="https://solo.example.com/")
    end

    test "every entry point goes straight to the account, with no wasted hop", %{conn: conn} do
      assert YouWeb.UserAuth.account_path() == ~p"/users/settings"
      assert YouWeb.UserAuth.account_label() == "Account"

      html = conn |> get(~p"/users/settings") |> html_response(200)

      refute html =~ ~s(href="/users/dashboard")
    end

    test "a fresh login lands on the account rather than bouncing through the hub", %{app: app} do
      user = You.AccountsFixtures.user_fixture() |> You.AccountsFixtures.set_password()
      _ = app

      conn =
        post(build_conn(), ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => You.AccountsFixtures.valid_user_password()
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
    end
  end

  describe "account hub in multi mode" do
    setup :register_and_log_in_user

    test "keeps the app grid as the account area", %{conn: conn} do
      assert YouWeb.UserAuth.account_path() == ~p"/users/dashboard"
      assert YouWeb.UserAuth.account_label() == "Dashboard"

      assert conn |> get(~p"/users/dashboard") |> html_response(200)
    end

    test "the settings page shows no single-app header", %{conn: conn} do
      html = conn |> get(~p"/users/settings") |> html_response(200)

      refute html =~ ~s(id="open-single-app")
    end
  end

  describe "console" do
    setup [:single_mode]

    setup %{conn: conn} do
      user = You.AccountsFixtures.user_fixture()
      Admin.promote_admin!(user)
      %{conn: log_in_user(conn, user)}
    end

    test "replaces the apps registry with a link to the one app", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console")

      assert html =~ "Application"
      assert html =~ ~s(href="/console/apps/solo")
      refute html =~ ~s(href="/console?view=apps")
    end

    test "refuses to render the apps registry", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console?view=apps")

      refute html =~ "Register app"
    end

    test "survives ?view= naming the single-app nav entry", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console?view=app")

      assert html =~ "Overview"
    end

    test "drops the per-app filter from the users view", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console?view=users")

      refute html =~ "all apps"
    end

    test "drops the per-app filter from the audit view", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console?view=audit")

      refute html =~ "all apps"
    end

    test "the access cell names the role without the app it is on", %{conn: conn, app: app} do
      user = You.AccountsFixtures.user_fixture()
      {:ok, _} = You.Roles.set_role(app, user, "admin")

      {:ok, _lv, html} = live(conn, ~p"/console?view=users")

      assert html =~ "admin"
      refute html =~ "admin·Solo"
      refute html =~ "+1 app"
    end

    test "the edit sheet labels the one role row rather than repeating the app", %{
      conn: conn,
      app: app
    } do
      user = You.AccountsFixtures.user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/console?view=users")

      html =
        lv
        |> element("button[phx-click='edit_user'][phx-value-id='#{user.id}']")
        |> render_click()

      assert html =~ "Roles on You and on this application."
      assert html =~ "Application"
      refute html =~ "Roles on You and on each app."
      assert html =~ ~s(id="edit-app-role-#{app.id}")
    end

    test "the nav follows the registered app when the configured slug drifted", %{conn: conn} do
      Application.put_env(:you, :single_app, slug: "does-not-exist", callback_url: @callback_url)

      {:ok, _lv, html} = live(conn, ~p"/console")

      assert html =~ ~s(href="/console/apps/solo")
      refute html =~ ~s(href="/console/apps/does-not-exist")
    end

    test "the per-app page still works", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console/apps/solo")

      assert html =~ "Solo"
    end
  end

  describe "console in multi mode" do
    setup %{conn: conn} do
      user = You.AccountsFixtures.user_fixture()
      Admin.promote_admin!(user)
      %{conn: log_in_user(conn, user)}
    end

    test "has an apps registry and a per-app filter", %{conn: conn} do
      {:ok, _lv, apps_html} = live(conn, ~p"/console?view=apps")
      {:ok, _lv, users_html} = live(conn, ~p"/console?view=users")

      assert apps_html =~ "Register app"
      assert users_html =~ "all apps"
    end
  end
end
