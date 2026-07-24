defmodule YouWeb.OIDCControllerTest do
  use YouWeb.ConnCase

  alias You.Accounts
  alias You.AccountsFixtures
  alias You.Admin
  alias You.JWT

  defp app_fixture do
    {:ok, app, secret} =
      Admin.create_app(%{
        slug: "test-app-#{System.unique_integer([:positive])}",
        name: "Test App",
        callback_url: "http://localhost/callback"
      })

    {app, secret}
  end

  defp exchange_code(conn, user, scopes, extra_params \\ %{}) do
    {:ok, code} = Accounts.generate_auth_code(user, scopes)

    conn
    |> post(~p"/oauth/token", Map.merge(%{code: code}, extra_params))
    |> json_response(200)
  end

  describe "GET /.well-known/openid-configuration" do
    test "returns discovery document with expected JSON shape", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/openid-configuration")

      assert %{
               "issuer" => issuer,
               "authorization_endpoint" => auth_endpoint,
               "token_endpoint" => token_endpoint,
               "userinfo_endpoint" => userinfo_endpoint,
               "introspection_endpoint" => introspection_endpoint,
               "revocation_endpoint" => revocation_endpoint,
               "jwks_uri" => jwks_uri,
               "response_types_supported" => ["code"],
               "grant_types_supported" => grant_types,
               "code_challenge_methods_supported" => ["S256"],
               "scopes_supported" => ["email", "profile", "roles"],
               "id_token_signing_alg_values_supported" => ["EdDSA"],
               "subject_types_supported" => ["public"],
               "token_endpoint_auth_methods_supported" => auth_methods,
               "claims_supported" => claims_supported
             } = json_response(conn, 200)

      assert String.starts_with?(issuer, "http://")
      assert auth_endpoint == "#{issuer}/users/log-in"
      assert token_endpoint == "#{issuer}/oauth/token"
      assert userinfo_endpoint == "#{issuer}/oauth/userinfo"
      assert introspection_endpoint == "#{issuer}/oauth/introspect"
      assert revocation_endpoint == "#{issuer}/oauth/revoke"
      assert jwks_uri == "#{issuer}/.well-known/jwks.json"
      assert Enum.sort(grant_types) == ["authorization_code", "refresh_token"]
      assert "client_secret_post" in auth_methods
      assert "none" in auth_methods
      assert "iss" in claims_supported
      assert "aud" in claims_supported
    end
  end

  describe "GET /.well-known/jwks.json" do
    test "returns JWKS with an Ed25519 public key", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/jwks.json")

      assert %{"keys" => [key | _]} = json_response(conn, 200)
      assert key["kty"] == "OKP"
      assert key["crv"] == "Ed25519"
      assert key["alg"] == "EdDSA"
      assert key["use"] == "sig"
      assert key["kid"] == "you-ed25519-v1"
      assert is_binary(key["x"])
      refute Map.has_key?(key, "d")

      # Verify the x value is valid base64url
      assert {:ok, decoded} = Base.url_decode64(key["x"], padding: false)
      assert byte_size(decoded) == 32
    end
  end

  describe "POST /oauth/token (authorization_code)" do
    setup do
      user = AccountsFixtures.user_fixture()
      {:ok, code} = Accounts.generate_auth_code(user)
      %{user: user, code: code}
    end

    test "returns access_token, id_token and refresh_token for a valid auth code", %{
      conn: conn,
      user: user,
      code: code
    } do
      conn = post(conn, ~p"/oauth/token", code: code)

      assert %{
               "access_token" => access_token,
               "id_token" => id_token,
               "token_type" => "Bearer",
               "expires_in" => expires_in,
               "refresh_token" => refresh_token
             } = json_response(conn, 200)

      assert is_binary(access_token)
      assert is_integer(expires_in)
      assert expires_in > 0
      assert is_binary(refresh_token)

      # Verify the token is valid and belongs to the right user
      assert {:ok, claims} = JWT.verify(access_token)
      assert claims["sub"] == user.id

      assert {:ok, id_claims} = JWT.verify(id_token)
      assert id_claims["sub"] == user.id
      assert id_claims["iss"] == YouWeb.Endpoint.url()
    end

    test "id_token carries the client_id as audience and scoped claims", %{
      conn: conn,
      user: user
    } do
      response =
        exchange_code(conn, user, ["email", "profile"], %{client_id: "consumer-app"})

      assert {:ok, id_claims} = JWT.verify(response["id_token"])
      assert id_claims["aud"] == "consumer-app"
      assert id_claims["email"] == user.email
      assert id_claims["name"] == user.email
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

  describe "POST /oauth/token (refresh_token grant)" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "rotates the refresh token and issues a fresh token set", %{conn: conn, user: user} do
      first = exchange_code(conn, user, ["email"])

      conn =
        post(conn, ~p"/oauth/token",
          grant_type: "refresh_token",
          refresh_token: first["refresh_token"]
        )

      assert %{
               "access_token" => access_token,
               "id_token" => id_token,
               "refresh_token" => new_refresh_token
             } = json_response(conn, 200)

      assert {:ok, claims} = JWT.verify(access_token)
      assert claims["sub"] == user.id
      assert {:ok, _} = JWT.verify(id_token)
      assert is_binary(new_refresh_token)
      refute new_refresh_token == first["refresh_token"]
    end

    test "old refresh token cannot be reused after rotation", %{conn: conn, user: user} do
      first = exchange_code(conn, user, ["email"])

      params = %{grant_type: "refresh_token", refresh_token: first["refresh_token"]}

      assert json_response(post(conn, ~p"/oauth/token", params), 200)

      assert %{"error" => "invalid_grant"} =
               json_response(post(conn, ~p"/oauth/token", params), 400)
    end

    test "returns invalid_grant for an unknown refresh token", %{conn: conn} do
      conn =
        post(conn, ~p"/oauth/token",
          grant_type: "refresh_token",
          refresh_token: "not-a-real-token"
        )

      assert %{"error" => "invalid_grant"} = json_response(conn, 400)
    end

    test "returns invalid_request when refresh_token parameter is missing", %{conn: conn} do
      conn = post(conn, ~p"/oauth/token", grant_type: "refresh_token")

      assert %{"error" => "invalid_request"} = json_response(conn, 400)
    end
  end

  describe "GET /oauth/userinfo" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "returns scoped claims for a valid access token", %{conn: conn, user: user} do
      %{"access_token" => access_token} = exchange_code(conn, user, ["email", "roles"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> get(~p"/oauth/userinfo")

      assert %{"sub" => sub, "email" => email, "role" => "user"} = json_response(conn, 200)
      assert sub == user.id
      assert email == user.email
    end

    test "returns 401 without an Authorization header", %{conn: conn} do
      conn = get(conn, ~p"/oauth/userinfo")

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
      assert get_resp_header(conn, "www-authenticate") != []
    end

    test "returns 401 for a garbage token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer garbage")
        |> get(~p"/oauth/userinfo")

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
    end

    test "returns 401 for an expired token", %{conn: conn, user: user} do
      {:ok, expired} = JWT.sign(%{sub: user.id, email: user.email}, -3600)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{expired}")
        |> get(~p"/oauth/userinfo")

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
    end

    test "returns 401 for a revoked token", %{conn: conn, user: user} do
      %{"access_token" => access_token} = exchange_code(conn, user, ["email"])
      :ok = JWT.revoke(access_token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> get(~p"/oauth/userinfo")

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
    end
  end

  describe "POST /oauth/introspect" do
    setup do
      user = AccountsFixtures.user_fixture()
      {app, secret} = app_fixture()
      %{user: user, app: app, secret: secret}
    end

    test "returns active with claims for a valid token", %{
      conn: conn,
      user: user,
      app: app,
      secret: secret
    } do
      %{"access_token" => access_token} = exchange_code(conn, user, ["email"])

      conn =
        post(conn, ~p"/oauth/introspect",
          client_id: app.slug,
          client_secret: secret,
          token: access_token
        )

      assert %{"active" => true, "sub" => sub, "email" => email} = json_response(conn, 200)
      assert sub == user.id
      assert email == user.email
    end

    test "returns active false for invalid, expired, and revoked tokens", %{
      conn: conn,
      user: user,
      app: app,
      secret: secret
    } do
      auth = %{client_id: app.slug, client_secret: secret}
      %{"access_token" => access_token} = exchange_code(conn, user, ["email"])
      :ok = JWT.revoke(access_token)
      {:ok, expired} = JWT.sign(%{sub: user.id}, -3600)

      for token <- ["garbage", access_token, expired] do
        conn = post(conn, ~p"/oauth/introspect", Map.put(auth, :token, token))
        assert %{"active" => false} = json_response(conn, 200)
      end
    end

    test "returns 401 for invalid client credentials", %{conn: conn, app: app} do
      conn =
        post(conn, ~p"/oauth/introspect",
          client_id: app.slug,
          client_secret: "wrong-secret",
          token: "whatever"
        )

      assert %{"error" => "invalid_client"} = json_response(conn, 401)
    end

    test "returns 400 when the token parameter is missing", %{
      conn: conn,
      app: app,
      secret: secret
    } do
      conn = post(conn, ~p"/oauth/introspect", client_id: app.slug, client_secret: secret)

      assert %{"error" => "invalid_request"} = json_response(conn, 400)
    end
  end

  describe "POST /oauth/revoke" do
    setup do
      user = AccountsFixtures.user_fixture()
      {app, secret} = app_fixture()
      %{user: user, app: app, secret: secret}
    end

    test "revokes a token so userinfo and verification reject it", %{
      conn: conn,
      user: user,
      app: app,
      secret: secret
    } do
      %{"access_token" => access_token} = exchange_code(conn, user, ["email"])

      conn =
        post(conn, ~p"/oauth/revoke",
          client_id: app.slug,
          client_secret: secret,
          token: access_token
        )

      assert json_response(conn, 200)
      assert {:error, :revoked} = JWT.verify(access_token)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> get(~p"/oauth/userinfo")

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
    end

    test "always returns 200 for unknown or malformed tokens", %{
      conn: conn,
      app: app,
      secret: secret
    } do
      for token <- ["not-a-token", ""] do
        conn =
          post(conn, ~p"/oauth/revoke",
            client_id: app.slug,
            client_secret: secret,
            token: token
          )

        assert json_response(conn, 200)
      end

      # No token param at all is still a success per RFC 7009.
      conn = post(conn, ~p"/oauth/revoke", client_id: app.slug, client_secret: secret)
      assert json_response(conn, 200)
    end

    test "returns 401 for invalid client credentials", %{conn: conn, app: app} do
      conn =
        post(conn, ~p"/oauth/revoke",
          client_id: app.slug,
          client_secret: "wrong-secret",
          token: "whatever"
        )

      assert %{"error" => "invalid_client"} = json_response(conn, 401)
    end
  end
end
