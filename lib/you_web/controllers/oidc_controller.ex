defmodule YouWeb.OIDCController do
  use YouWeb, :controller

  alias You.Accounts
  alias You.JWT

  @doc """
  GET /.well-known/openid-configuration

  Returns the OIDC Discovery Document so third-party consumers can discover
  endpoints programmatically.

  # JWKS note

  The provider signs JWTs with **Ed25519** (EdDSA). The `jwks_uri` exposes the
  public verification key as a standard JWK Set (OKP / Ed25519).
  """
  def discovery(conn, _params) do
    base = YouWeb.Endpoint.url()

    config = %{
      issuer: base,
      authorization_endpoint: "#{base}/users/log-in",
      token_endpoint: "#{base}/oauth/token",
      jwks_uri: "#{base}/.well-known/jwks.json",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code"],
      scopes_supported: ["email", "profile", "roles"],
      id_token_signing_alg_values_supported: ["EdDSA"],
      subject_types_supported: ["public"],
      token_endpoint_auth_methods_supported: ["none"],
      claims_supported: ["sub", "email", "name", "role"]
    }

    json(conn, config)
  end

  @doc """
  GET /.well-known/jwks.json

  Returns the public verification key as a JWK Set.

  The signing key is Ed25519 (asymmetric), so the JWK carries the public part
  of the key pair under the OKP key type with curve Ed25519. The algorithm is
  EdDSA.
  """
  def jwks(conn, _params) do
    jwk = JWT.jwk()
    public_jwk = JOSE.JWK.to_public(jwk)
    {_alg, key_fields} = JOSE.JWK.to_map(public_jwk)

    # JOSE.JWK.to_map/1 returns the key fields with values already in JWK
    # format — the `x` member is already base64url-encoded.
    key = %{
      "kty" => key_fields["kty"],
      "crv" => key_fields["crv"],
      "x" => key_fields["x"],
      "alg" => "EdDSA",
      "kid" => "you-ed25519-v1",
      "use" => "sig"
    }

    json(conn, %{keys: [key]})
  end

  @doc """
  POST /oauth/token

  Exchanges an authorization code for an access token (JWT) and a refresh
  token. This is the HTTP twin of the Erlang-distribution `exchange_code` call
  on `You.IAM.Server`.
  """
  def create_token(conn, %{"code" => code}) do
    case Accounts.consume_auth_code(code) do
      {:ok, user, scopes} ->
        jwt_expiry = You.Settings.get(:jwt_expiry_hours) * 3600
        {:ok, jwt} = JWT.sign(build_scoped_claims(user, scopes), jwt_expiry)
        refresh_token = Accounts.create_refresh_token(user, scopes)

        :telemetry.execute([:you, :audit, :token, :exchange], %{}, %{
          user_id: user.id,
          scopes: scopes
        })

        conn
        |> put_status(:ok)
        |> json(%{
          access_token: jwt,
          token_type: "Bearer",
          expires_in: jwt_expiry,
          refresh_token: refresh_token
        })

      {:error, :not_found} ->
        :telemetry.execute([:you, :audit, :token, :exchange], %{}, %{
          result: :failure,
          reason: :not_found
        })

        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_grant",
          error_description: "The authorization code is invalid or has expired."
        })
    end
  end

  def create_token(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "invalid_request",
      error_description: "Missing required parameter: code."
    })
  end

  # Builds the JWT claims map for the granted scopes. Mirrors the private
  # `build_scoped_claims/2` in You.IAM.Server.
  defp build_scoped_claims(user, scopes) do
    base = %{sub: user.id, app: "you"}

    scopes
    |> Enum.reduce(base, fn
      "email", acc -> Map.put(acc, :email, user.email)
      "profile", acc -> acc |> Map.put(:email, user.email) |> Map.put(:name, user.email)
      "roles", acc -> acc |> Map.put(:email, user.email) |> Map.put(:role, user_role(user))
      _, acc -> acc
    end)
  end

  defp user_role(%{is_admin: true}), do: "admin"
  defp user_role(_), do: "user"
end
