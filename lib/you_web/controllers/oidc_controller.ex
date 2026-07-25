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
      token_endpoint_auth_methods_supported: ["client_secret_post", "none"],
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

    * `authorization_code`: exchanges an authorization code (with optional
      PKCE `code_verifier`) for an access token, id_token, and refresh token.
      This is the HTTP twin of the Erlang-distribution `exchange_code` call
      on `You.IAM.Server`. The `grant_type` parameter may be omitted for
      backward compatibility.
    * `refresh_token`: rotates a refresh token (single-use) and issues a
      fresh token set for the same user and scopes.
  """
  def create_token(conn, %{"grant_type" => "refresh_token"} = params) do
    case params do
      %{"refresh_token" => refresh_token} ->
        exchange_refresh_token(conn, refresh_token, params["client_id"])

      _ ->
        invalid_request(conn, "Missing required parameter: refresh_token.")
    end
  end

  def create_token(conn, %{"code" => code} = params) do
    case Accounts.consume_auth_code(code, params["code_verifier"]) do
      {:ok, user, scopes, app_slug} ->
        response = OIDC.issue_token_response(user, scopes, params["client_id"], nil, app_slug)

        :telemetry.execute([:you, :audit, :token, :exchange], %{}, %{
          user_id: user.id,
          scopes: scopes
        })

        conn
        |> put_status(:ok)
        |> json(response)

      {:error, reason} when reason in [:not_found, :invalid_grant] ->
        :telemetry.execute([:you, :audit, :token, :exchange], %{}, %{
          result: :failure,
          reason: reason
        })

        description =
          case reason do
            :invalid_grant -> "PKCE verification failed."
            :not_found -> "The authorization code is invalid or has expired."
          end

        invalid_grant(conn, description)
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

  defp exchange_refresh_token(conn, refresh_token, client_id) do
    case Accounts.rotate_refresh_token(refresh_token) do
      {:ok, user, scopes, new_refresh_token, app_slug} ->
        response = OIDC.issue_token_response(user, scopes, client_id, new_refresh_token, app_slug)

        :telemetry.execute([:you, :audit, :token, :refresh], %{}, %{
          user_id: user.id,
          scopes: scopes
        })

        conn
        |> put_status(:ok)
        |> json(response)

      {:error, :invalid} ->
        invalid_grant(conn, "The refresh token is invalid or has expired.")
    end
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

  defp invalid_grant(conn, description) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_grant", error_description: description})
  end
end
