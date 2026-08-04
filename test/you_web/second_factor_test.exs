defmodule YouWeb.SecondFactorTest do
  @moduledoc """
  The second factor belongs to the account, not to the method that proved the
  first one. Before #112 only the password path checked, so a magic link or any
  enabled identity provider signed a TOTP-enrolled account straight in.
  """
  use YouWeb.ConnCase, async: false

  import You.AccountsFixtures

  alias You.Accounts

  setup do
    You.Admin.create_app(%{
      slug: "myapp",
      name: "Myapp",
      callback_url: "https://myapp.example.com/auth/callback"
    })

    :ok
  end

  defp with_totp(user) do
    {:ok, setup} = Accounts.generate_totp_setup(user)
    {:ok, result} = Accounts.enable_totp(setup.user, NimbleTOTP.verification_code(setup.secret))
    result.user
  end

  defp magic_link_token(user) do
    extract_user_token(fn url -> Accounts.deliver_login_instructions(user, url) end)
  end

  describe "magic link" do
    test "a TOTP-enrolled account is challenged instead of signed in", %{conn: conn} do
      user = user_fixture() |> with_totp()
      token = magic_link_token(user)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      assert redirected_to(conn) == ~p"/users/log-in/totp"
      assert get_session(conn, :totp_user_id) == user.id
      refute get_session(conn, :user_token)
    end

    test "the challenge still completes into the app's OAuth callback", %{conn: conn} do
      user = user_fixture() |> with_totp()
      token = magic_link_token(user)

      conn = get(conn, ~p"/users/log-in", callback_url: "https://myapp.example.com/auth/callback")
      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})
      assert redirected_to(conn) == ~p"/users/log-in/totp"

      conn =
        post(conn, ~p"/users/log-in/totp", %{
          "totp" => %{"code" => NimbleTOTP.verification_code(user.totp_secret)}
        })

      assert redirected_to(conn, 302) =~ "https://myapp.example.com/auth/callback?code="
    end

    test "an email-2FA account is challenged instead of signed in", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Accounts.enable_email_2fa(user)
      token = magic_link_token(user)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      assert redirected_to(conn) == ~p"/users/log-in/email-2fa"
      assert get_session(conn, :email_2fa_user_id) == user.id
      refute get_session(conn, :user_token)
    end

    test "an account with no second factor is signed in as before", %{conn: conn} do
      user = user_fixture()
      token = magic_link_token(user)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      assert get_session(conn, :user_token)
    end
  end

  # The federated callback needs an upstream token/userinfo exchange to reach
  # its success branch, so the gate it shares with every other first factor is
  # asserted directly.
  describe "the gate itself" do
    test "TOTP takes precedence and stashes the pending user", %{conn: conn} do
      user = user_fixture() |> with_totp()

      assert {:challenge, conn} =
               conn |> init_test_session(%{}) |> YouWeb.SecondFactor.challenge(user)

      assert redirected_to(conn) == ~p"/users/log-in/totp"
      assert get_session(conn, :totp_user_id) == user.id
    end

    test "an unenrolled account passes through", %{conn: conn} do
      assert :none =
               conn |> init_test_session(%{}) |> YouWeb.SecondFactor.challenge(user_fixture())
    end
  end
end
