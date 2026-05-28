defmodule YouWeb.ApiAuthTest do
  use YouWeb.ConnCase, async: false

  alias You.AccountsFixtures

  describe "POST /api/login" do
    test "returns JWT for valid email and password" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      conn =
        post(build_conn(), ~p"/api/login", %{
          email: user.email,
          password: AccountsFixtures.valid_user_password()
        })

      assert json_response(conn, 200)["jwt"]
    end

    test "returns 401 for invalid password" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      conn =
        post(build_conn(), ~p"/api/login", %{
          email: user.email,
          password: "wrong password"
        })

      assert json_response(conn, 401)
    end

    test "returns 401 for unknown email" do
      conn =
        post(build_conn(), ~p"/api/login", %{
          email: "nonexistent@example.com",
          password: "some password"
        })

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/login with 2FA" do
    test "returns 2fa_required when user has 2FA enabled" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      # Enable 2FA
      {:ok, setup} = You.Accounts.generate_totp_setup(user)
      valid_code = NimbleTOTP.verification_code(setup.secret)
      {:ok, _} = You.Accounts.enable_totp(setup.user, valid_code)

      conn =
        post(build_conn(), ~p"/api/login", %{
          email: user.email,
          password: AccountsFixtures.valid_user_password()
        })

      resp = json_response(conn, 200)
      assert resp["status"] == "2fa_required"
      assert resp["pre_auth_token"]
    end

    test "verify 2FA with valid TOTP code returns JWT" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      {:ok, setup} = You.Accounts.generate_totp_setup(user)
      valid_code = NimbleTOTP.verification_code(setup.secret)
      {:ok, _} = You.Accounts.enable_totp(setup.user, valid_code)

      # Get pre-auth token
      login_conn =
        post(build_conn(), ~p"/api/login", %{
          email: user.email,
          password: AccountsFixtures.valid_user_password()
        })

      %{"pre_auth_token" => pre_auth} = json_response(login_conn, 200)

      # Verify with TOTP code
      verify_conn =
        post(build_conn(), ~p"/api/login/verify", %{
          pre_auth_token: pre_auth,
          totp_code: valid_code
        })

      resp = json_response(verify_conn, 200)
      assert resp["jwt"]
    end

    test "verify 2FA with invalid TOTP code returns 401" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      {:ok, setup} = You.Accounts.generate_totp_setup(user)
      valid_code = NimbleTOTP.verification_code(setup.secret)
      {:ok, _} = You.Accounts.enable_totp(setup.user, valid_code)

      login_conn =
        post(build_conn(), ~p"/api/login", %{
          email: user.email,
          password: AccountsFixtures.valid_user_password()
        })

      %{"pre_auth_token" => pre_auth} = json_response(login_conn, 200)

      verify_conn =
        post(build_conn(), ~p"/api/login/verify", %{
          pre_auth_token: pre_auth,
          totp_code: "000000"
        })

      assert json_response(verify_conn, 401)
    end
  end

  describe "DELETE /api/logout" do
    test "revokes the JWT in the Authorization header" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      login_conn =
        post(build_conn(), ~p"/api/login", %{
          email: user.email,
          password: AccountsFixtures.valid_user_password()
        })

      %{"jwt" => jwt} = json_response(login_conn, 200)

      # Can verify the token before logout
      assert {:ok, _claims} = You.JWT.verify(jwt)

      # Logout
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{jwt}")
        |> delete(~p"/api/logout")

      assert response(conn, 204)

      # Token is now revoked
      assert {:error, :revoked} = You.JWT.verify(jwt)
    end

    test "returns 401 without Authorization header" do
      conn = delete(build_conn(), ~p"/api/logout")
      assert json_response(conn, 401)
    end
  end
end
