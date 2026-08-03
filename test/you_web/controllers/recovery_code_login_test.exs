defmodule YouWeb.RecoveryCodeLoginTest do
  use YouWeb.ConnCase, async: false

  alias You.Accounts
  alias You.Admin
  alias You.AccountsFixtures

  describe "recovery code during login" do
    setup do
      Admin.create_app(%{
        slug: "myapp",
        name: "Myapp",
        callback_url: "https://myapp.example.com/auth/callback"
      })

      user = AccountsFixtures.user_fixture()

      {:ok, {user, _}} =
        Accounts.update_user_password(user, %{password: AccountsFixtures.valid_user_password()})

      {:ok, setup} = Accounts.generate_totp_setup(user)
      valid_code = NimbleTOTP.verification_code(setup.secret)
      {:ok, result} = Accounts.enable_totp(setup.user, valid_code)

      %{user: result.user, recovery_codes: result.recovery_codes}
    end

    defp login_with_password(conn, user) do
      conn = get(conn, ~p"/users/log-in", callback_url: "https://myapp.example.com/auth/callback")

      post(conn, ~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => AccountsFixtures.valid_user_password()}
      })
    end

    test "a valid recovery code logs the user in", %{
      conn: conn,
      user: user,
      recovery_codes: [code | _]
    } do
      conn = login_with_password(conn, user)
      assert get_session(conn, :totp_user_id)

      conn = post(conn, ~p"/users/log-in/totp/recovery", %{"recovery" => %{"code" => code}})

      location = redirected_to(conn, 302)
      assert String.starts_with?(location, "https://myapp.example.com/auth/callback?code=")
    end

    test "the same recovery code cannot be used twice", %{
      conn: conn,
      user: user,
      recovery_codes: [code | _]
    } do
      conn = login_with_password(conn, user)
      conn = post(conn, ~p"/users/log-in/totp/recovery", %{"recovery" => %{"code" => code}})
      assert redirected_to(conn, 302)

      conn2 = login_with_password(build_conn(), user)
      conn2 = post(conn2, ~p"/users/log-in/totp/recovery", %{"recovery" => %{"code" => code}})

      response = html_response(conn2, 200)
      assert response =~ "Invalid or already-used recovery code."
    end

    test "an invalid recovery code fails", %{conn: conn, user: user} do
      conn = login_with_password(conn, user)

      conn =
        post(conn, ~p"/users/log-in/totp/recovery", %{
          "recovery" => %{"code" => "not-a-real-code"}
        })

      response = html_response(conn, 200)
      assert response =~ "Invalid or already-used recovery code."
    end

    test "a used code does not block a different valid one", %{
      conn: conn,
      user: user,
      recovery_codes: [first, second | _]
    } do
      conn = login_with_password(conn, user)
      conn = post(conn, ~p"/users/log-in/totp/recovery", %{"recovery" => %{"code" => first}})
      assert redirected_to(conn, 302)

      conn2 = login_with_password(build_conn(), user)
      conn2 = post(conn2, ~p"/users/log-in/totp/recovery", %{"recovery" => %{"code" => second}})
      assert redirected_to(conn2, 302)
    end

    test "emits a login:attempt audit event identifying the recovery-code method", %{
      conn: conn,
      user: user,
      recovery_codes: [code | _]
    } do
      test_pid = self()

      :telemetry.attach(
        "recovery-code-test-handler",
        [:you, :audit, :login, :attempt],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("recovery-code-test-handler") end)

      conn = login_with_password(conn, user)
      post(conn, ~p"/users/log-in/totp/recovery", %{"recovery" => %{"code" => code}})

      assert_receive {:telemetry_event, _measurements, %{method: "recovery_code"} = metadata},
                     1_000

      assert metadata.result == :success
      assert metadata.user_id == user.id
    end
  end
end
