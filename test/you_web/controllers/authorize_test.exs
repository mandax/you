defmodule YouWeb.AuthorizeTest do
  use YouWeb.ConnCase

  alias You.AccountsFixtures

  setup :register_and_log_in_user

  describe "GET /login with callback_url when already logged in" do
    test "shows authorize page instead of login form", %{conn: conn} do
      conn =
        get(conn, ~p"/users/log-in", callback_url: "https://sockeet.example.com/auth/callback")

      assert html_response(conn, 200) =~ "Authorize"
      assert html_response(conn, 200) =~ "sockeet.example.com"
    end
  end
end
