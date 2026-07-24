defmodule YouWeb.AuthorizeTest do
  use YouWeb.ConnCase

  setup :register_and_log_in_user

  describe "GET /login with callback_url when already logged in" do
    test "shows authorize page instead of login form", %{conn: conn} do
      conn =
        get(conn, ~p"/users/log-in", callback_url: "https://myapp.example.com/auth/callback")

      assert html_response(conn, 200) =~ "Authorize"
      assert html_response(conn, 200) =~ "myapp.example.com"
    end
  end
end
