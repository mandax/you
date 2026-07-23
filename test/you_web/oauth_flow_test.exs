defmodule YouWeb.OAuthFlowTest do
  use YouWeb.ConnCase, async: false

  alias YouWeb.OAuthFlow
  alias You.Accounts

  @cb "https://app.example.com/cb"

  setup %{conn: conn} do
    {:ok, _app, _secret} =
      You.Admin.create_app(%{slug: "app1", name: "App One", callback_url: @cb})

    %{conn: conn, user: You.AccountsFixtures.user_fixture()}
  end

  defp code_param(url), do: URI.decode_query(URI.parse(url).query) |> Map.get("code")

  test "in an OAuth flow, mints a code and redirects to the consumer callback", %{
    conn: conn,
    user: user
  } do
    conn =
      conn
      |> init_test_session(callback_url: @cb, scopes: ["email"], state: "st-123")
      |> OAuthFlow.complete_login(user)

    loc = redirected_to(conn)
    assert String.starts_with?(loc, @cb <> "?")
    assert loc =~ "state=st-123"

    # the code resolves to this user (proves it was minted for them)
    assert {:ok, resolved, ["email"]} = Accounts.consume_auth_code(code_param(loc))
    assert resolved.id == user.id
  end

  test "binds the minted code to the PKCE challenge", %{conn: conn, user: user} do
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    conn =
      conn
      |> init_test_session(callback_url: @cb, scopes: ["email"], code_challenge: challenge)
      |> OAuthFlow.complete_login(user)

    code = code_param(redirected_to(conn))
    # wrong verifier is rejected (and burns the code)
    assert {:error, :invalid_grant} = Accounts.consume_auth_code(code, "wrong-verifier")
  end

  test "refuses an unregistered callback_url (no open redirect)", %{conn: conn, user: user} do
    conn =
      conn
      |> init_test_session(callback_url: "https://evil.example.com/cb", scopes: ["email"])
      |> OAuthFlow.complete_login(user)

    # falls through to a plain You login, not a redirect to the attacker URL
    refute redirected_to(conn) =~ "evil.example.com"
    assert get_session(conn, :user_token)
  end

  test "without a callback_url, logs into You", %{conn: conn, user: user} do
    conn = conn |> init_test_session(%{}) |> OAuthFlow.complete_login(user)

    assert redirected_to(conn) == ~p"/users/dashboard"
    assert get_session(conn, :user_token)
  end
end
