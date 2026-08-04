defmodule YouWeb.TotpLoginTest do
  use YouWeb.ConnCase

  alias You.Accounts
  alias You.Admin
  alias You.AccountsFixtures

  describe "2FA during login" do
    setup do
      Admin.create_app(%{
        slug: "myapp",
        name: "Myapp",
        callback_url: "https://myapp.example.com/auth/callback"
      })

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
        get(conn, ~p"/users/log-in", callback_url: "https://myapp.example.com/auth/callback")

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
        get(conn, ~p"/users/log-in", callback_url: "https://myapp.example.com/auth/callback")

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
      assert String.starts_with?(location, "https://myapp.example.com/auth/callback?code=")
    end

    test "GET /users/log-in/totp renders the TOTP challenge, not the magic-link route", %{
      conn: conn,
      user: user
    } do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => AccountsFixtures.valid_user_password()}
        })

      # Follow the 302 the browser would follow — this GET used to be captured
      # by /users/log-in/:token and 302 back with "magic link is invalid".
      conn = get(conn, ~p"/users/log-in/totp")
      response = html_response(conn, 200)
      assert response =~ "Two-Factor Authentication"
      refute response =~ "magic link"
    end

    test "a successful TOTP verification emits login:totp", %{conn: conn, user: user} do
      metadata = capture_totp_event(conn, user, NimbleTOTP.verification_code(user.totp_secret))

      assert metadata.result == :success
      assert metadata.method == "totp"
      assert metadata.user_id == user.id
    end

    test "a failed TOTP verification emits login:totp", %{conn: conn, user: user} do
      metadata = capture_totp_event(conn, user, "000000")

      assert metadata.result == :failure
      assert metadata.user_id == user.id
    end

    defp capture_totp_event(conn, user, code) do
      test_pid = self()
      handler_id = "totp-audit-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:you, :audit, :login, :totp],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:totp_event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => AccountsFixtures.valid_user_password()}
        })

      post(conn, ~p"/users/log-in/totp", %{"totp" => %{"code" => code}})

      assert_receive {:totp_event, metadata}, 1_000
      metadata
    end
  end
end
