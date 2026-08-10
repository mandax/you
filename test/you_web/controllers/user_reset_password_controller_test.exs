defmodule YouWeb.UserResetPasswordControllerTest do
  use YouWeb.ConnCase, async: true

  import Ecto.Query
  import You.AccountsFixtures

  alias You.Accounts
  alias You.Accounts.UserToken
  alias You.Repo

  @cb "https://app.example.com/cb"
  @evil "https://evil.example.com/cb"

  setup do
    %{user: user_fixture()}
  end

  defp reset_token(user) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    You.Repo.insert!(user_token)
    encoded_token
  end

  defp code_param(url), do: URI.decode_query(URI.parse(url).query) |> Map.get("code")

  describe "PUT /users/reset-password/:token with a callback_url in session" do
    test "an unregistered callback_url does not receive the code (no open redirect, no leaked code)",
         %{conn: conn, user: user} do
      token = reset_token(user)

      conn =
        conn
        |> init_test_session(callback_url: @evil, scopes: ["email"])
        |> put(~p"/users/reset-password/#{token}", %{
          "user" => %{
            "password" => valid_user_password(),
            "password_confirmation" => valid_user_password()
          }
        })

      # no external redirect to the attacker's host — at most an internal
      # redirect to You's own log-in page (which echoes callback_url as a
      # query param for the *next* login attempt, itself re-validated at
      # that flow's own completion; it is never followed here).
      refute String.starts_with?(redirected_to(conn), "http")
      assert redirected_to(conn) == YouWeb.AppBranding.login_path(conn)

      # the password did change...
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())

      # ...but no auth code was ever minted for the attacker's app.
      assert Repo.aggregate(from(t in UserToken, where: t.context == "oauth_code"), :count) == 0
    end

    test "a registered app's callback_url still receives the code end to end", %{
      conn: conn,
      user: user
    } do
      {:ok, _app, _secret} =
        You.Admin.create_app(%{slug: "app1", name: "App One", callback_url: @cb})

      token = reset_token(user)

      conn =
        conn
        |> init_test_session(callback_url: @cb, scopes: ["email"])
        |> put(~p"/users/reset-password/#{token}", %{
          "user" => %{
            "password" => valid_user_password(),
            "password_confirmation" => valid_user_password()
          }
        })

      loc = redirected_to(conn)
      assert String.starts_with?(loc, @cb <> "?")

      assert {:ok, resolved, ["email"], "app1"} =
               Accounts.consume_auth_code(code_param(loc), nil, client_authenticated: true)

      assert resolved.id == user.id
    end

    test "no callback_url in session falls back to the ordinary post-reset destination", %{
      conn: conn,
      user: user
    } do
      token = reset_token(user)

      conn =
        put(conn, ~p"/users/reset-password/#{token}", %{
          "user" => %{
            "password" => valid_user_password(),
            "password_confirmation" => valid_user_password()
          }
        })

      assert redirected_to(conn) == YouWeb.AppBranding.login_path(conn)
    end
  end
end
