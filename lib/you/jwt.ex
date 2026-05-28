defmodule You.JWT do
  @moduledoc """
  JWT signing and verification using Ed25519 via `jose`.

  The signing key is cached in application config so all processes on this
  node share the same key. For production, configure a persistent key:

      config :you, You.JWT, jwk: %JOSE.JWK{...}

  If no key is configured, one is generated on first call and cached.
  """

  alias You.Repo
  alias You.Accounts.UserToken

  # 24 hours
  @default_exp 86_400

  @doc """
  Returns the configured or auto-generated JWK, cached in application config.
  """
  def jwk do
    case Application.get_env(:you, You.JWT, [])[:jwk] do
      nil ->
        jwk = JOSE.JWK.generate_key({:okp, :Ed25519})
        Application.put_env(:you, You.JWT, jwk: jwk)
        jwk

      jwk ->
        jwk
    end
  end

  @doc """
  Signs claims into a JWT string. Adds `jti`, `iat`, `exp`.

  ## Examples

      {:ok, token} = JWT.sign(%{sub: user.id, email: user.email, app: "sockeet", role: "admin"})

  """
  def sign(claims) do
    sign(claims, @default_exp)
  end

  def sign(claims, exp_seconds) do
    now = DateTime.utc_now()

    claims =
      Map.merge(claims, %{
        "jti" => :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false),
        "iat" => DateTime.to_unix(now),
        "exp" => DateTime.to_unix(now) + exp_seconds
      })

    jwk = jwk()

    {:ok, jose_compact(jwk, claims)}
  end

  @doc """
  Verifies a JWT. Checks signature, expiry, and blocklist.

  Returns `{:ok, claims}` or `{:error, reason}`.
  """
  def verify(signed) when is_binary(signed) do
    with {:ok, payload} <- jose_verify(signed),
         :ok <- check_expiry(payload),
         {:ok, payload} <- check_blocklist(payload) do
      {:ok, payload}
    end
  end

  @doc """
  Extracts the JTI (JWT ID) from a signed JWT. Returns the JTI string.
  """
  def extract_jti(signed) when is_binary(signed) do
    {:ok, payload} = jose_verify(signed)
    payload["jti"]
  end

  @doc """
  Revokes a JWT by adding its JTI to the blocklist. Returns `:ok`.
  """
  def revoke(signed) when is_binary(signed) do
    with {:ok, payload} <- jose_verify(signed) do
      jti = payload["jti"]
      sub = payload["sub"]

      %UserToken{
        token: hash_jti(jti),
        context: "jti_revoked",
        user_id: sub
      }
      |> Repo.insert()

      :telemetry.execute([:you, :audit, :token, :revoke], %{}, %{
        user_id: sub,
        jti: jti
      })

      :ok
    else
      _ -> :ok
    end
  end

  # -- JOSE boundary: wrap Erlang library that can crash into tagged tuples

  defp jose_compact(jwk, claims) do
    {_alg_map, compact} = JOSE.JWT.sign(jwk, claims) |> JOSE.JWS.compact()
    compact
  end

  defp jose_verify(signed) do
    jwk = jwk()

    case JOSE.JWT.verify(jwk, signed) do
      {true, jwt, _jws} ->
        {_protected, payload} = JOSE.JWT.to_map(jwt)
        {:ok, payload}

      {false, _, _} ->
        {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  # -- Expiry

  defp check_expiry(%{"exp" => exp}) do
    now_unix = DateTime.to_unix(DateTime.utc_now())

    if now_unix > exp do
      {:error, :expired}
    else
      :ok
    end
  end

  defp check_expiry(_payload), do: :ok

  # -- Blocklist

  defp check_blocklist(payload) do
    hashed = hash_jti(payload["jti"])

    case Repo.get_by(UserToken, token: hashed, context: "jti_revoked") do
      nil -> {:ok, payload}
      _ -> {:error, :revoked}
    end
  end

  defp hash_jti(jti) do
    :crypto.hash(:sha256, jti)
  end
end
