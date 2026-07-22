defmodule YouWeb.OIDCControllerTest do
  use YouWeb.ConnCase

  alias You.Accounts
  alias You.AccountsFixtures

  describe "GET /.well-known/openid-configuration" do
    test "returns discovery document with expected JSON shape", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/openid-configuration")

      assert %{
               "issuer" => issuer,
               "authorization_endpoint" => auth_endpoint,
               "token_endpoint" => token_endpoint,
               "jwks_uri" => jwks_uri,
               "response_types_supported" => ["code"],
               "grant_types_supported" => ["authorization_code"],
               "code_challenge_methods_supported" => ["S256"],
               "scopes_supported" => ["email", "profile", "roles"],
               "id_token_signing_alg_values_supported" => ["EdDSA"],
               "subject_types_supported" => ["public"],
               "token_endpoint_auth_methods_supported" => ["none"],
               "claims_supported" => ["sub", "email", "name", "role"]
             } = json_response(conn, 200)

      assert String.starts_with?(issuer, "http://")
      assert auth_endpoint == "#{issuer}/users/log-in"
      assert token_endpoint == "#{issuer}/oauth/token"
      assert jwks_uri == "#{issuer}/.well-known/jwks.json"
    end
  end

  describe "GET /.well-known/jwks.json" do
    test "returns JWKS with an Ed25519 public key", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/jwks.json")

      assert %{"keys" => [key]} = json_response(conn, 200)
      assert key["kty"] == "OKP"
      assert key["crv"] == "Ed25519"
      assert key["alg"] == "EdDSA"
      assert key["use"] == "sig"
      assert key["kid"] == "you-ed25519-v1"
      assert is_binary(key["x"])

      # Verify the x value is valid base64url
      assert {:ok, decoded} = Base.url_decode64(key["x"], padding: false)
      assert byte_size(decoded) == 32
    end
  end

  describe "POST /oauth/token" do
    setup do
      user = AccountsFixtures.user_fixture()
      {:ok, code} = Accounts.generate_auth_code(user)
      %{user: user, code: code}
    end

    test "returns access_token for a valid auth code", %{conn: conn, user: user, code: code} do
      conn = post(conn, ~p"/oauth/token", code: code)

      assert %{
               "access_token" => access_token,
               "token_type" => "Bearer",
               "expires_in" => expires_in,
               "refresh_token" => refresh_token
             } = json_response(conn, 200)

      assert is_binary(access_token)
      assert is_integer(expires_in)
      assert expires_in > 0
      assert is_binary(refresh_token)

      # Verify the token is valid and belongs to the right user
      assert {:ok, claims} = You.JWT.verify(access_token)
      assert claims["sub"] == user.id
    end

    test "returns invalid_grant for an invalid auth code", %{conn: conn} do
      conn = post(conn, ~p"/oauth/token", code: "this-code-does-not-exist")

      assert %{"error" => "invalid_grant"} = json_response(conn, 400)
    end

    test "returns invalid_request when code parameter is missing", %{conn: conn} do
      conn = post(conn, ~p"/oauth/token", %{})

      assert %{"error" => "invalid_request"} = json_response(conn, 400)
    end

    test "auth code is single-use", %{conn: conn, code: code} do
      # First use succeeds
      conn1 = post(conn, ~p"/oauth/token", code: code)
      assert json_response(conn1, 200)

      # Second use with the same code fails
      conn2 = post(conn, ~p"/oauth/token", code: code)
      assert %{"error" => "invalid_grant"} = json_response(conn2, 400)
    end

    test "PKCE: correct verifier succeeds, wrong one is rejected", %{conn: conn, user: user} do
      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      {:ok, bad} = Accounts.generate_auth_code(user, ["email"], challenge)
      resp = post(conn, ~p"/oauth/token", code: bad, code_verifier: "nope")
      assert %{"error" => "invalid_grant"} = json_response(resp, 400)

      {:ok, good} = Accounts.generate_auth_code(user, ["email"], challenge)
      resp = post(conn, ~p"/oauth/token", code: good, code_verifier: verifier)
      assert %{"access_token" => _} = json_response(resp, 200)
    end
  end
end
