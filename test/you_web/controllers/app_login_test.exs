defmodule YouWeb.AppLoginTest do
  use YouWeb.ConnCase

  alias You.AccountsFixtures

  describe "GET /login with callback_url" do
    test "stores callback_url in session", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in", callback_url: "https://sockeet.example.com/auth/callback")
      assert get_session(conn, :callback_url) == "https://sockeet.example.com/auth/callback"
    end
  end

    describe "POST /login after callback_url auth code flow" do
    setup do
      user = AccountsFixtures.user_fixture()
      {:ok, {user, _}} = You.Accounts.update_user_password(user, %{password: AccountsFixtures.valid_user_password()})
      %{user: user}
    end

    test "redirects to callback_url with auth code after password login", %{conn: conn, user: user} do
      # Store callback_url in session by hitting the login page first
      conn = get(conn, ~p"/users/log-in", callback_url: "https://sockeet.example.com/auth/callback")
      assert get_session(conn, :callback_url) == "https://sockeet.example.com/auth/callback"

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => AccountsFixtures.valid_user_password()}
        })

      assert redirected_to(conn, 302)
      location = redirected_to(conn, 302)
      assert String.starts_with?(location, "https://sockeet.example.com/auth/callback?code=")
    end
  end
end
