defmodule YouWeb.OIDCController do
  use YouWeb, :controller

  alias You.Accounts
  alias You.JWT
  alias You.OIDC

  @doc """
  GET /.well-known/openid-configuration

  Returns the OIDC Discovery Document so third-party consumers can discover
  endpoints programmatically.

  # JWKS note

  The provider signs JWTs with **Ed25519** (EdDSA). The `jwks_uri` exposes the
  public verification keys as a standard JWK Set (OKP / Ed25519).
  """
  def discovery(conn, _params) do
    base = YouWeb.Endpoint.url()

    config = %{
      issuer: base,
      authorization_endpoint: "#{base}/users/log-in",
      token_endpoint: "#{base}/oauth/token",
      userinfo_endpoint: "#{base}/oauth/userinfo",
      introspection_endpoint: "#{base}/oauth/introspect",
      revocation_endpoint: "#{base}/oauth/revoke",
      jwks_uri: "#{base}/.well-known/jwks.json",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      scopes_supported: ["email", "profile", "roles"],
      id_token_signing_alg_values_supported: ["EdDSA"],
      subject_types_supported: ["public"],
      token_endpoint_auth_methods_supported: [
        "client_secret_basic",
        "client_secret_post",
        "none"
      ],
      claims_supported: ["iss", "sub", "aud", "exp", "iat", "email", "name", "role"]
    }

    json(conn, config)
  end

  @doc """
  GET /.well-known/jwks.json

  Returns the public verification keys (current and previous) as a JWK Set.

  The signing keys are Ed25519 (asymmetric), so each JWK carries the public
  part of a key pair under the OKP key type with curve Ed25519. The algorithm
  is EdDSA.
  """
  def jwks(conn, _params) do
    json(conn, JWT.public_jwks())
  end

  @doc """
  POST /oauth/token

  Handles two grants:

    * `authorization_code`: exchanges an authorization code for an access
      token, id_token, and refresh token. The `grant_type` parameter may be
      omitted for backward compatibility. This is the HTTP twin of the
      Erlang-distribution `exchange_code` call on `You.IAM.Server`, which is
      trusted by transport and needs no credentials.
    * `refresh_token`: rotates a refresh token (single-use) and issues a
      fresh token set for the same user and scopes.

  ## Client authentication

  The authorization-code grant requires the client to prove it is the one the
  code was issued to, either way round:

    * **Confidential clients** send `client_id` + `client_secret`, as HTTP
      Basic (RFC 6749 §2.3.1) or in the body (`client_secret_post`).
    * **Public clients** (SPA, mobile) send the PKCE `code_verifier` for a code
      that was bound to a `code_challenge` at authorization time.

  An exchange presenting neither is rejected with `invalid_client`, and so is a
  code redeemed by a client other than the one it was issued to.
  """
  def create_token(conn, %{"grant_type" => "refresh_token"} = params) do
    with {:ok, client_id} <- token_client(conn, params),
         %{"refresh_token" => refresh_token} <- params do
      exchange_refresh_token(conn, refresh_token, client_id)
    else
      {:error, :invalid_client} ->
        reject_client(conn, "Client authentication failed.")

      _ ->
        invalid_request(conn, "Missing required parameter: refresh_token.")
    end
  end

  def create_token(conn, %{"code" => code} = params) do
    verifier = params["code_verifier"]

    case authenticate_token_client(conn, params) do
      {:ok, app} ->
        exchange_auth_code(conn, code, verifier, app.slug, true)

      :none when is_binary(verifier) ->
        exchange_auth_code(conn, code, verifier, params["client_id"], false)

      :none ->
        exchange_failure(conn, :no_client_auth)

      {:error, :invalid_client} ->
        exchange_failure(conn, :bad_client_credentials)
    end
  end

  def create_token(conn, _params) do
    invalid_request(conn, "Missing required parameter: code.")
  end

  @doc """
  GET /oauth/userinfo

  Returns the scoped identity claims for a valid Bearer access token. The JTI
  blocklist is enforced, so revoked tokens are rejected.
  """
  def userinfo(conn, _params) do
    with [token] <- bearer_tokens(conn),
         {:ok, claims} <- OIDC.userinfo_claims(token) do
      json(conn, claims)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> put_resp_header("www-authenticate", ~s(Bearer error="invalid_token"))
        |> json(%{error: "invalid_token"})
    end
  end

  @doc """
  POST /oauth/introspect

  RFC 7662 token introspection. Requires client authentication via
  `client_id`/`client_secret` in the POST body (`client_secret_post`).
  """
  def introspect(conn, params) do
    with {:ok, _app} <- OIDC.authenticate_client(params["client_id"], params["client_secret"]),
         {:ok, token} <- fetch_token_param(params) do
      json(conn, OIDC.introspect(token))
    else
      {:error, :invalid_client} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_client"})

      {:error, :missing_token} ->
        invalid_request(conn, "Missing required parameter: token.")
    end
  end

  @doc """
  POST /oauth/revoke

  RFC 7009 token revocation: adds the token's JTI to the blocklist. Client
  authentication is required as for introspection; per spec the response is
  always 200 for authenticated requests, even when the token is unknown,
  malformed, or already revoked.
  """
  def revoke(conn, params) do
    case OIDC.authenticate_client(params["client_id"], params["client_secret"]) do
      {:ok, _app} ->
        if token = params["token"], do: JWT.revoke(token)
        json(conn, %{})

      {:error, :invalid_client} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_client"})
    end
  end

  defp exchange_auth_code(conn, code, verifier, client_id, authenticated?) do
    case Accounts.consume_auth_code(code, verifier, client_authenticated: authenticated?) do
      {:ok, user, scopes, app_slug} ->
        if issued_to?(app_slug, client_id) do
          response = OIDC.issue_token_response(user, scopes, client_id, nil, app_slug)

          :telemetry.execute([:you, :audit, :token, :exchange], %{}, %{
            user_id: user.id,
            scopes: scopes
          })

          conn
          |> put_status(:ok)
          |> json(response)
        else
          exchange_failure(conn, :client_mismatch)
        end

      {:error, reason} ->
        exchange_failure(conn, reason)
    end
  end

  defp exchange_failure(conn, reason) do
    :telemetry.execute([:you, :audit, :token, :exchange], %{}, %{
      result: :failure,
      reason: reason
    })

    case reason do
      :no_client_auth ->
        reject_client(
          conn,
          "The token endpoint requires either client_secret authentication or a " <>
            "PKCE code_verifier."
        )

      :bad_client_credentials ->
        reject_client(conn, "Client authentication failed.")

      :invalid_client ->
        reject_client(
          conn,
          "The authorization code was not bound to a PKCE challenge, so it can only be " <>
            "redeemed by a client authenticating with its client_secret."
        )

      :client_mismatch ->
        invalid_grant(conn, "The authorization code was issued to a different client.")

      :invalid_grant ->
        invalid_grant(conn, "PKCE verification failed.")

      :not_found ->
        invalid_grant(conn, "The authorization code is invalid or has expired.")
    end
  end

  defp issued_to?(nil, _client_id), do: true
  defp issued_to?(_app_slug, nil), do: true
  defp issued_to?(app_slug, client_id), do: app_slug == client_id

  defp exchange_refresh_token(conn, refresh_token, client_id) do
    case Accounts.rotate_refresh_token(refresh_token) do
      {:ok, user, scopes, new_refresh_token, app_slug} ->
        if issued_to?(app_slug, client_id) do
          response =
            OIDC.issue_token_response(user, scopes, client_id, new_refresh_token, app_slug)

          :telemetry.execute([:you, :audit, :token, :refresh], %{}, %{
            user_id: user.id,
            scopes: scopes
          })

          conn
          |> put_status(:ok)
          |> json(response)
        else
          :telemetry.execute([:you, :audit, :token, :refresh], %{}, %{
            result: :failure,
            reason: :client_mismatch
          })

          invalid_grant(conn, "The refresh token was issued to a different client.")
        end

      {:error, :invalid} ->
        invalid_grant(conn, "The refresh token is invalid or has expired.")
    end
  end

  defp token_client(conn, params) do
    case authenticate_token_client(conn, params) do
      {:ok, app} -> {:ok, app.slug}
      :none -> {:ok, params["client_id"]}
      error -> error
    end
  end

  defp authenticate_token_client(conn, params) do
    case presented_credentials(conn, params) do
      {client_id, client_secret} -> OIDC.authenticate_client(client_id, client_secret)
      :none -> :none
    end
  end

  defp presented_credentials(conn, params) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {client_id, client_secret} ->
        {decode_credential(client_id), decode_credential(client_secret)}

      :error ->
        body_credentials(params)
    end
  end

  defp body_credentials(%{"client_id" => client_id, "client_secret" => client_secret})
       when is_binary(client_id) and is_binary(client_secret),
       do: {client_id, client_secret}

  defp body_credentials(_params), do: :none

  # RFC 6749 §2.3.1 form-urlencodes both halves of the Basic credential.
  defp decode_credential(value) do
    URI.decode_www_form(value)
  rescue
    ArgumentError -> value
  end

  defp bearer_tokens(conn) do
    for header <- get_req_header(conn, "authorization"),
        ["Bearer", token] <- [String.split(header, " ", parts: 2)] do
      token
    end
  end

  defp fetch_token_param(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp fetch_token_param(_params), do: {:error, :missing_token}

  defp invalid_request(conn, description) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request", error_description: description})
  end

  defp reject_client(conn, description) do
    conn
    |> put_status(:unauthorized)
    |> maybe_challenge_basic()
    |> json(%{error: "invalid_client", error_description: description})
  end

  defp maybe_challenge_basic(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      :error -> conn
      _ -> put_resp_header(conn, "www-authenticate", ~s(Basic realm="oauth"))
    end
  end

  defp invalid_grant(conn, description) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_grant", error_description: description})
  end
end
