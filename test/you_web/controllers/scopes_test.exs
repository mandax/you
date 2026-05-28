defmodule YouWeb.ScopesTest do
  use YouWeb.ConnCase

  alias You.AccountsFixtures

  describe "scope parameter in login URL" do
    test "stores scope in session when present", %{conn: conn} do
      conn =
        get(conn, ~p"/users/log-in",
          callback_url: "https://sockeet.example.com/auth/callback",
          scope: "email profile"
        )

      assert get_session(conn, :scopes) == ["email", "profile"]
    end

    test "defaults to email scope when not specified", %{conn: conn} do
      conn =
        get(conn, ~p"/users/log-in", callback_url: "https://sockeet.example.com/auth/callback")

      assert get_session(conn, :scopes) == ["email"]
    end
  end
end
