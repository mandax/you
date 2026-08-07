defmodule YouWeb.LoginAuditRequestHostTest do
  @moduledoc """
  Pins `request_host_claimed` — the raw, unvalidated `Host` header recorded
  on the login audit events — for every method that has a `conn` to read it
  from: password, recovery-code, TOTP, and federated (OIDC/social). One test
  per method, per the #122 review that found this field otherwise had zero
  coverage.

  The headless, guest and registration paths in `You.IAM.Server` are not
  covered here because they carry no `request_host_claimed` at all — those
  calls arrive over Erlang distribution, not HTTP, so there is no Host
  header to record.
  """

  use YouWeb.ConnCase, async: false

  alias You.Accounts
  alias You.AccountsFixtures
  alias You.IdentityProviders

  @request_host "acme.example.com"

  defp with_request_host(conn), do: %{conn | host: @request_host}

  defp attach_and_await(event, fun) do
    test_pid = self()
    handler_id = "login-audit-host-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn _event, _measurements, metadata, _config -> send(test_pid, {:audit_event, metadata}) end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)

    fun.()

    assert_receive {:audit_event, metadata}, 1_000
    metadata
  end

  describe "password login" do
    test "carries the Host header claimed at the request, unvalidated", %{conn: conn} do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      metadata =
        attach_and_await([:you, :audit, :login, :attempt], fn ->
          conn
          |> with_request_host()
          |> post(~p"/users/log-in", %{
            "user" => %{
              "email" => user.email,
              "password" => AccountsFixtures.valid_user_password()
            }
          })
        end)

      assert metadata.method == "password"
      assert metadata.request_host_claimed == @request_host
    end
  end

  describe "recovery-code login" do
    setup do
      user = AccountsFixtures.user_fixture()

      {:ok, {user, _}} =
        Accounts.update_user_password(user, %{password: AccountsFixtures.valid_user_password()})

      {:ok, setup} = Accounts.generate_totp_setup(user)
      valid_code = NimbleTOTP.verification_code(setup.secret)
      {:ok, result} = Accounts.enable_totp(setup.user, valid_code)

      %{user: result.user, recovery_codes: result.recovery_codes}
    end

    test "carries the Host header claimed at the request, unvalidated", %{
      conn: conn,
      user: user,
      recovery_codes: [code | _]
    } do
      conn =
        conn
        |> with_request_host()
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => AccountsFixtures.valid_user_password()
          }
        })

      metadata =
        attach_and_await([:you, :audit, :login, :attempt], fn ->
          post(conn, ~p"/users/log-in/totp/recovery", %{"recovery" => %{"code" => code}})
        end)

      assert metadata.method == "recovery_code"
      assert metadata.request_host_claimed == @request_host
    end
  end

  describe "TOTP login" do
    setup do
      user = AccountsFixtures.user_fixture()

      {:ok, {user, _}} =
        Accounts.update_user_password(user, %{password: AccountsFixtures.valid_user_password()})

      {:ok, setup} = Accounts.generate_totp_setup(user)
      valid_code = NimbleTOTP.verification_code(setup.secret)
      {:ok, result} = Accounts.enable_totp(setup.user, valid_code)

      %{user: result.user}
    end

    test "carries the Host header claimed at the request, unvalidated", %{conn: conn, user: user} do
      conn =
        conn
        |> with_request_host()
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => AccountsFixtures.valid_user_password()
          }
        })

      code = NimbleTOTP.verification_code(user.totp_secret)

      metadata =
        attach_and_await([:you, :audit, :login, :totp], fn ->
          post(conn, ~p"/users/log-in/totp", %{"totp" => %{"code" => code}})
        end)

      assert metadata.method == "totp"
      assert metadata.request_host_claimed == @request_host
    end
  end

  describe "federated (OIDC/social) login" do
    @google_attrs %{
      "slug" => "google",
      "display_name" => "Google",
      "kind" => "google",
      "client_id" => "gid",
      "client_secret" => "gsecret",
      "issuer" => "https://accounts.google.com",
      "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
      "token_url" => "https://oauth2.googleapis.com/token",
      "userinfo_url" => "https://openidconnect.googleapis.com/v1/userinfo",
      "scopes" => "openid email profile"
    }

    @tag :capture_log
    test "a failed callback still carries the Host header claimed at the request", %{
      conn: conn
    } do
      {:ok, _provider} = IdentityProviders.create_provider(@google_attrs)

      # State matches, so the flow reaches the token exchange — which fails
      # here for lack of network access to Google, landing on the generic
      # `{:error, reason}` branch that emits the audit event. That's enough
      # to prove `request_host_claimed` survives an OIDC failure path; the
      # success path is exercised end-to-end in federated_auth_controller_test.exs.
      metadata =
        attach_and_await([:you, :audit, :login, :attempt], fn ->
          conn
          |> with_request_host()
          |> init_test_session(oidc_state: "st")
          |> get(~p"/auth/google/callback", %{"code" => "x", "state" => "st"})
        end)

      assert metadata.method == "oidc:google"
      assert metadata.request_host_claimed == @request_host
    end
  end
end
