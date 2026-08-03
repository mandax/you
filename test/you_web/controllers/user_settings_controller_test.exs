defmodule YouWeb.UserSettingsControllerTest do
  use YouWeb.ConnCase

  alias You.Accounts
  import You.AccountsFixtures

  setup :register_and_log_in_user

  describe "GET /users/settings" do
    test "renders settings page", %{conn: conn} do
      conn = get(conn, ~p"/users/settings")
      response = html_response(conn, 200)
      assert response =~ "Settings"
    end

    test "redirects if user is not logged in" do
      conn = build_conn()
      conn = get(conn, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    @tag token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
    test "redirects if user is not in sudo mode", %{conn: conn} do
      conn = get(conn, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must re-authenticate to access this page."
    end

    test "warns when recovery codes are running low", %{conn: conn, user: user} do
      {:ok, %{secret: secret}} = Accounts.generate_totp_setup(user)
      user = Accounts.get_user!(user.id)
      {:ok, _} = Accounts.enable_totp(user, NimbleTOTP.verification_code(secret))
      user = Accounts.get_user!(user.id)

      for code <- Enum.take(elem(Accounts.regenerate_recovery_codes(user), 1), 6) do
        Accounts.verify_recovery_code(user, code)
      end

      assert Accounts.count_unused_recovery_codes(user) == 2

      conn = get(conn, ~p"/users/settings")
      response = html_response(conn, 200)
      assert response =~ "Running low on recovery codes"
    end

    test "does not warn when recovery codes are plentiful", %{conn: conn, user: user} do
      {:ok, %{secret: secret}} = Accounts.generate_totp_setup(user)
      user = Accounts.get_user!(user.id)
      {:ok, _} = Accounts.enable_totp(user, NimbleTOTP.verification_code(secret))

      conn = get(conn, ~p"/users/settings")
      response = html_response(conn, 200)
      refute response =~ "Running low on recovery codes"
    end
  end

  describe "PUT /users/settings (change password form)" do
    test "updates the user password and resets tokens", %{conn: conn, user: user} do
      new_password_conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_password",
          "user" => %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "does not update password on invalid data", %{conn: conn} do
      old_password_conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_password",
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      response = html_response(old_password_conn, 200)
      assert response =~ "Settings"
      assert response =~ "should be at least 12 character(s)"
      assert response =~ "does not match password"

      assert get_session(old_password_conn, :user_token) == get_session(conn, :user_token)
    end
  end

  describe "PUT /users/settings (change email form)" do
    @tag :capture_log
    test "updates the user email", %{conn: conn, user: user} do
      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_email",
          "user" => %{"email" => unique_user_email()}
        })

      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "A link to confirm your email"

      assert Accounts.get_user_by_email(user.email)
    end

    test "does not update email on invalid data", %{conn: conn} do
      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      response = html_response(conn, 200)
      assert response =~ "Settings"
      assert response =~ "must have the @ sign and no spaces"
    end
  end

  describe "GET /users/settings/confirm-email/:token" do
    setup %{user: user} do
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{token: token, email: email}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")
      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Email changed successfully"

      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")

      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "Email change link is invalid or it has expired"
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      conn = get(conn, ~p"/users/settings/confirm-email/oops")
      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "Email change link is invalid or it has expired"

      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "GET /users/settings/totp" do
    test "renders setup page with QR code and code form", %{conn: conn, user: user} do
      refute user.totp_enabled

      conn = get(conn, ~p"/users/settings/totp")
      response = html_response(conn, 200)
      assert response =~ "<svg"
      assert response =~ "code"
    end

    test "redirects if TOTP is already enabled", %{conn: conn, user: user} do
      {:ok, %{secret: secret}} = Accounts.generate_totp_setup(user)
      user = Accounts.get_user!(user.id)
      {:ok, _} = Accounts.enable_totp(user, NimbleTOTP.verification_code(secret))

      conn = get(conn, ~p"/users/settings/totp")
      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "already enabled"
    end

    @tag token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
    test "redirects if user is not in sudo mode", %{conn: conn} do
      conn = get(conn, ~p"/users/settings/totp")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/settings/totp" do
    test "enables TOTP with a valid code and shows recovery codes", %{conn: conn, user: user} do
      {:ok, %{secret: secret}} = Accounts.generate_totp_setup(user)
      valid_code = NimbleTOTP.verification_code(secret)

      conn = post(conn, ~p"/users/settings/totp", %{"code" => valid_code})
      response = html_response(conn, 200)
      assert response =~ "Recovery codes"
      assert response =~ "These codes will not be shown again"

      db_user = Accounts.get_user!(user.id)
      assert db_user.totp_enabled
    end

    test "re-renders setup with error on invalid code", %{conn: conn, user: user} do
      {:ok, _} = Accounts.generate_totp_setup(user)

      conn = post(conn, ~p"/users/settings/totp", %{"code" => "000000"})
      response = html_response(conn, 200)
      assert response =~ "Set up authenticator app"
      assert response =~ "Invalid code"

      db_user = Accounts.get_user!(user.id)
      refute db_user.totp_enabled
    end

    @tag token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
    test "redirects if user is not in sudo mode", %{conn: conn} do
      conn = post(conn, ~p"/users/settings/totp", %{"code" => "000000"})
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "DELETE /users/settings/totp" do
    test "disables TOTP and redirects to settings", %{conn: conn, user: user} do
      {:ok, %{secret: secret}} = Accounts.generate_totp_setup(user)
      user = Accounts.get_user!(user.id)
      {:ok, _} = Accounts.enable_totp(user, NimbleTOTP.verification_code(secret))

      conn = delete(conn, ~p"/users/settings/totp")
      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "disabled"

      db_user = Accounts.get_user!(user.id)
      refute db_user.totp_enabled
    end

    @tag token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
    test "redirects if user is not in sudo mode", %{conn: conn} do
      conn = delete(conn, ~p"/users/settings/totp")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/settings/totp/recovery-codes" do
    setup %{conn: conn, user: user} do
      {:ok, %{secret: secret}} = Accounts.generate_totp_setup(user)
      user = Accounts.get_user!(user.id)

      {:ok, %{recovery_codes: old_codes}} =
        Accounts.enable_totp(user, NimbleTOTP.verification_code(secret))

      %{conn: conn, user: Accounts.get_user!(user.id), old_codes: old_codes}
    end

    test "replaces the recovery code set and shows the new codes", %{
      conn: conn,
      user: user,
      old_codes: old_codes
    } do
      conn = post(conn, ~p"/users/settings/totp/recovery-codes")
      response = html_response(conn, 200)
      assert response =~ "Recovery codes"
      assert response =~ "These codes will not be shown again"

      assert Accounts.count_unused_recovery_codes(user) == 8

      for code <- old_codes do
        assert {:error, :invalid_code} = Accounts.verify_recovery_code(user, code)
      end
    end

    test "old codes stop working even if never used", %{conn: conn, user: user} do
      post(conn, ~p"/users/settings/totp/recovery-codes")

      assert Accounts.count_unused_recovery_codes(user) == 8
    end

    test "refuses when TOTP is not enabled" do
      %{conn: conn} = log_in_fresh_user()

      conn = post(conn, ~p"/users/settings/totp/recovery-codes")
      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "not enabled"
    end

    @tag token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
    test "redirects if user is not in sudo mode", %{conn: conn} do
      conn = post(conn, ~p"/users/settings/totp/recovery-codes")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  defp log_in_fresh_user do
    user = user_fixture()
    %{conn: log_in_user(build_conn(), user), user: user}
  end
end
