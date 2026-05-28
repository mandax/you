defmodule You.SDK.Verify do
  @moduledoc false

  # Local JWT verification using You's Ed25519 public key.
  # Consumer apps use this to verify JWTs without calling You's API.

  @doc """
  Verifies a JWT using You's Ed25519 public key.

  The `public_key` must be a JWK map as returned by `You.SDK.fetch_public_key/1`.

  Returns `{:ok, claims}` or `{:error, reason}`.
  """
  def verify(signed, public_key) when is_binary(signed) do
    jwk = JOSE.JWK.from(public_key)

    case JOSE.JWT.verify(jwk, signed) do
      {true, jwt, _jws} ->
        {_protected, payload} = JOSE.JWT.to_map(jwt)
        now_unix = DateTime.to_unix(DateTime.utc_now())

        if exp = payload["exp"] do
          if now_unix > exp do
            {:error, :expired}
          else
            {:ok, payload}
          end
        else
          {:ok, payload}
        end

      {false, _, _} ->
        {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  @doc """
  Converts You's internal JWK to a portable JWK map suitable for
  distribution to client apps.

  The returned map can be serialized to JSON and distributed to
  client apps for local JWT verification.
  """
  def export_public_key do
    jwk = You.JWT.jwk()
    {:ok, pub} = JOSE.JWK.to_public(jwk)
    {jwk_map, _} = JOSE.JWK.to_map(pub)
    jwk_map
  end
end
