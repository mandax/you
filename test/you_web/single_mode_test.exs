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
    Application.put_env(:you, :mode, :single)
    Application.put_env(:you, :single_app, slug: "solo", callback_url: @callback_url)

    on_exit(fn ->
      Application.put_env(:you, :mode, :multi)
      Application.delete_env(:you, :single_app)
    end)

    :ok
  end

  describe "consent screen" do
    setup [:register_and_log_in_user, :single_mode]

    test "is skipped: the user goes straight back to the app with a code", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in?callback_url=#{@callback_url}&scope=email")

      assert redirected_to(conn) =~ "#{@callback_url}?code="
    end

    test "still records consent, so flipping to multi mode leaves no gap", %{
      conn: conn,
      user: user,
      app: app
    } do
      get(conn, ~p"/users/log-in?callback_url=#{@callback_url}&scope=email")

      assert [consented] = Accounts.list_consented_apps(user)
      assert consented.id == app.id
    end

    test "echoes the consumer's state back on the redirect", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in?callback_url=#{@callback_url}&state=xyz")

      assert redirected_to(conn) =~ "state=xyz"
    end
  end

  describe "consent screen in multi mode" do
    setup :register_and_log_in_user

    test "still asks the user to authorize", %{conn: conn} do
      html =
        conn
        |> get(~p"/users/log-in?callback_url=#{@callback_url}&scope=email")
        |> html_response(200)

      assert html =~ "Authorize"
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
