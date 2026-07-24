defmodule YouWeb.UserDashboardControllerTest do
  use YouWeb.ConnCase

  alias You.Accounts
  alias You.Admin

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, app, _secret} =
      Admin.create_app(%{
        slug: "myapp",
        name: "Myapp",
        callback_url: "https://myapp.example.com/auth/callback"
      })

    {:ok, other_app, _secret} =
      Admin.create_app(%{
        slug: "other",
        name: "Other",
        callback_url: "https://other.example.com/callback"
      })

    %{app: app, other_app: other_app, user: user}
  end

  describe "GET /users/dashboard" do
    test "shows apps the user has consented to", %{conn: conn, app: app, user: user} do
      {:ok, _} = Accounts.record_consent(user, app, ["email"])

      conn = get(conn, ~p"/users/dashboard")
      response = html_response(conn, 200)
      assert response =~ app.name
    end

    test "does not show unconsented apps", %{conn: conn, other_app: other_app} do
      conn = get(conn, ~p"/users/dashboard")
      response = html_response(conn, 200)
      refute response =~ other_app.name
    end

    test "shows empty state when user has no consents", %{conn: conn} do
      conn = get(conn, ~p"/users/dashboard")
      response = html_response(conn, 200)
      assert response =~ "haven't connected any apps"
    end
  end

  describe "DELETE /users/dashboard/apps/:app_id" do
    test "revokes access and redirects", %{conn: conn, app: app, user: user} do
      {:ok, _} = Accounts.record_consent(user, app, ["email"])
      assert length(Accounts.list_consented_apps(user)) == 1

      conn = delete(conn, ~p"/users/dashboard/apps/#{app.id}")
      assert redirected_to(conn) == ~p"/users/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ app.name

      assert Accounts.list_consented_apps(user) == []
    end

    test "handles non-existent app gracefully", %{conn: conn} do
      conn = delete(conn, ~p"/users/dashboard/apps/0")
      assert redirected_to(conn) == ~p"/users/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "App not found"
    end
  end
end
