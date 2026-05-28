defmodule You.SDK do
  @moduledoc """
  SDK for integrating apps with the You IAM service.

  Provides JWT verification (local, using You's Ed25519 public key)
  and HTTP client calls to You's REST API.

  ## Usage in a consumer app

      # Login
      You.SDK.login("https://you.example.com", email, password)

      # Verify a JWT locally
      You.SDK.verify(jwt, public_key)

      # Verify 2FA
      You.SDK.verify_2fa("https://you.example.com", pre_auth_token, totp_code)

  ## Configuration

  The SDK can be configured in the consumer app:

      config :you_sdk,
        url: "https://you.example.com",
        public_key: %{kty: "OKP", crv: "Ed25519", ...},
        http_timeout: 5_000
  """

  alias You.SDK.Client
  alias You.SDK.Verify

  @doc """
  Authenticates a user with email and password.

  Returns `{:ok, %{jwt: String.t()}}`,
  `{:ok, %{status: "2fa_required", pre_auth_token: String.t()}}`,
  or `{:error, reason}`.
  """
  def login(url, email, password) do
    Client.post(url, "/api/login", %{email: email, password: password})
  end

  @doc """
  Completes 2FA login with a pre-auth token and TOTP code.

  Returns `{:ok, %{jwt: String.t()}}` or `{:error, reason}`.
  """
  def verify_2fa(url, pre_auth_token, totp_code) do
    Client.post(url, "/api/login/verify", %{
      pre_auth_token: pre_auth_token,
      totp_code: totp_code
    })
  end

  @doc """
  Revokes a JWT session.

  Returns `:ok` or `{:error, reason}`.
  """
  def revoke(url, jwt) do
    case Client.delete(url, "/api/logout", jwt) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  @doc """
  Fetches You's Ed25519 public key in JWK format from the
  `.well-known/jwks.json` endpoint.

  Returns `{:ok, jwk_map}` or `{:error, reason}`.
  """
  def fetch_public_key(url) do
    Client.get(url, "/.well-known/jwks.json")
  end

  @doc """
  Verifies a JWT using You's Ed25519 public key.

  Checks signature and expiry. Returns `{:ok, claims}` or `{:error, reason}`.

  The `public_key` should be a JWK map fetched via `fetch_public_key/1`
  or configured in the consumer app.
  """
  def verify(jwt, public_key) do
    Verify.verify(jwt, public_key)
  end
end
