defmodule You.JWT do
  @moduledoc """
  JWT signing and verification using Ed25519 (EdDSA) via `jose`, backed by a
  key store: one current signing key plus optional previous keys kept for
  verification only.

  ## Configuration

      config :you, You.JWT,
        current_kid: "you-ed25519-v2",
        keys: %{
          "you-ed25519-v2" => %JOSE.JWK{...},
          "you-ed25519-v1" => %JOSE.JWK{...}
        }

  With no `:keys` configured, a key is generated on first call and cached in
  application env under the default kid `"you-ed25519-v1"`, which is fine for
  dev, but tokens stop verifying after a restart. Configure persistent keys for
  production.

  ## Rotation

  1. Generate a new Ed25519 key, add it to `:keys` under a fresh kid, and
     point `:current_kid` at it. New tokens are signed and stamped with the
     new kid; tokens signed by the old key still verify because their kid
     resolves to the old key in the store.
  2. Keep the old key in `:keys` until every token it signed has expired
     (see `You.Settings` `:jwt_expiry_hours`), then drop it. JWKS only ever
     exposes the public parts, so consumers pick up new keys automatically.

  Legacy tokens signed before kids existed carry no `kid` header; those are
  verified against every key in the store.
  """

  alias You.Repo
  alias You.Accounts.RevokedJti

  @default_exp 86_400
  @default_kid "you-ed25519-v1"

  @doc """
  Returns the kid of the current signing key.
  """
  def current_kid do
    config()[:current_kid] || @default_kid
  end

  @doc """
  Signs claims into a JWT string with the current key. Adds `jti`, `iat`,
  `exp`, and stamps the header with the current `kid`.

  ## Examples

      {:ok, token} = JWT.sign(%{sub: user.id, email: user.email, app: "consumer-app", role: "admin"})

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

    kid = current_kid()
    jwk = Map.fetch!(key_store(), kid)

    {:ok, jose_compact(jwk, kid, claims)}
  end

  @doc """
  Verifies a JWT. Selects the verification key by the token's `kid` header
  (falling back to all store keys for legacy tokens without one), then checks
  signature, expiry, and blocklist.

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
  Returns the public JWK Set (`%{"keys" => [...]}`) for every key in the
  store, ready to serve from the JWKS endpoint.
  """
  def public_jwks do
    keys =
      for {kid, jwk} <- key_store() do
        {_alg, fields} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

        %{
          "kty" => fields["kty"],
          "crv" => fields["crv"],
          "x" => fields["x"],
          "alg" => "EdDSA",
          "kid" => kid,
          "use" => "sig"
        }
      end

    %{"keys" => keys}
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

  Idempotent: revoking the same token twice is a success, as RFC 7009 requires
  of `/oauth/revoke`, and clients do retry it after a network failure. Works
  for service tokens too, whose subject is an app slug rather than a user id.
  """
  def revoke(signed) when is_binary(signed) do
    with {:ok, payload} <- jose_verify(signed) do
      jti = payload["jti"]
      sub = payload["sub"]

      %RevokedJti{}
      |> RevokedJti.changeset(%{jti_hash: hash_jti(jti), subject: to_string(sub)})
      |> Repo.insert(on_conflict: :nothing, conflict_target: :jti_hash)

      :telemetry.execute([:you, :audit, :token, :revoke], %{}, %{
        user_id: sub,
        jti: jti
      })

      :ok
    else
      _ -> :ok
    end
  end

  # -- Key store

  defp config do
    Application.get_env(:you, You.JWT, [])
  end

  defp key_store do
    case config()[:keys] do
      keys when is_map(keys) and map_size(keys) > 0 ->
        keys

      _ ->
        kid = current_kid()
        jwk = JOSE.JWK.generate_key({:okp, :Ed25519})
        Application.put_env(:you, You.JWT, Keyword.put(config(), :keys, %{kid => jwk}))
        %{kid => jwk}
    end
  end

  # -- JOSE boundary: wrap Erlang library that can crash into tagged tuples

  defp jose_compact(jwk, kid, claims) do
    protected = %{"alg" => "EdDSA", "kid" => kid}

    {_alg_map, compact} =
      JOSE.JWT.sign(jwk, protected, claims) |> JOSE.JWS.compact()

    compact
  end

  defp jose_verify(signed) do
    store = key_store()

    kids =
      case header_kid(signed) do
        nil -> Map.keys(store)
        kid -> [kid]
      end

    Enum.reduce_while(kids, {:error, :invalid_signature}, fn kid, acc ->
      with {:ok, jwk} <- Map.fetch(store, kid),
           {true, jwt, _jws} <- JOSE.JWT.verify_strict(jwk, ["EdDSA"], signed) do
        {_protected, payload} = JOSE.JWT.to_map(jwt)
        {:halt, {:ok, payload}}
      else
        _ -> {:cont, acc}
      end
    end)
  rescue
    _ -> {:error, :invalid_signature}
  end

  # Reads the kid straight from the compact header without touching JOSE, so
  # malformed tokens simply yield no kid.
  defp header_kid(signed) do
    with [header | _] <- String.split(signed, "."),
         {:ok, json} <- Base.url_decode64(header, padding: false),
         {:ok, %{"kid" => kid}} when is_binary(kid) <- Jason.decode(json) do
      kid
    else
      _ -> nil
    end
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

  defp check_blocklist(%{"jti" => jti} = payload) when is_binary(jti) do
    hashed = hash_jti(jti)

    case Repo.get_by(RevokedJti, jti_hash: hashed) do
      nil -> {:ok, payload}
      _ -> {:error, :revoked}
    end
  end

  defp check_blocklist(payload), do: {:ok, payload}

  defp hash_jti(jti) do
    :crypto.hash(:sha256, jti)
  end
end
