defmodule YouWeb.ScopesTest do
  use YouWeb.ConnCase

  describe "scope parameter in login URL" do
    test "stores scope in session when present", %{conn: conn} do
      conn =
        get(conn, ~p"/users/log-in",
          callback_url: "https://sockeet.example.com/auth/callback",
          scope: "email profile"
        )

      assert get_session(conn, :scopes) == ["email", "profile"]
    end

    test "sets scopes to nil when not specified", %{conn: conn} do
      conn =
        get(conn, ~p"/users/log-in", callback_url: "https://sockeet.example.com/auth/callback")

      assert get_session(conn, :scopes) == nil
    end
  end
end
