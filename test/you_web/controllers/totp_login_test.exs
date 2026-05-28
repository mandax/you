defmodule YouWeb.TotpLoginTest do
  use YouWeb.ConnCase

  alias You.Accounts
  alias You.AccountsFixtures

  describe "2FA during login" do
    setup do
      user = AccountsFixtures.user_fixture()

      {:ok, {user, _}} =
        Accounts.update_user_password(user, %{password: AccountsFixtures.valid_user_password()})

      # Enable TOTP for the user
      {:ok, setup} = Accounts.generate_totp_setup(user)
      valid_code = NimbleTOTP.verification_code(setup.secret)
      {:ok, _result} = Accounts.enable_totp(setup.user, valid_code)
      %{user: setup.user}
    end

    test "redirects to TOTP challenge after password login when 2FA enabled", %{
      conn: conn,
      user: user
    } do
      conn =
        get(conn, ~p"/users/log-in", callback_url: "https://sockeet.example.com/auth/callback")

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => AccountsFixtures.valid_user_password()}
        })

      assert redirected_to(conn, 302)
      assert redirected_to(conn, 302) =~ ~p"/users/log-in/totp"
    end

    test "valid TOTP code after 2FA login redirects to callback_url with auth code", %{
      conn: conn,
      user: user
    } do
      # Step 1: Login with password (sets totp_user_id in session)
      conn =
        get(conn, ~p"/users/log-in", callback_url: "https://sockeet.example.com/auth/callback")

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => AccountsFixtures.valid_user_password()}
        })

      assert get_session(conn, :totp_user_id)

      # Step 2: Generate the current TOTP code from the user's stored secret
      valid_code = NimbleTOTP.verification_code(user.totp_secret)

      conn =
        post(conn, ~p"/users/log-in/totp", %{
          "totp" => %{"code" => valid_code}
        })

      assert redirected_to(conn, 302)
      location = redirected_to(conn, 302)
      assert String.starts_with?(location, "https://sockeet.example.com/auth/callback?code=")
    end
  end
end
