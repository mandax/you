defmodule You.IdentityProviders.Crypto do
  @moduledoc """
  AES-256-GCM encryption for `identity_providers.client_secret`, keyed off the
  endpoint's `secret_key_base` rather than a separate managed key — this app
  has no key-management service, and the secret already gates every signed
  cookie and token, so deriving from it adds no new key to protect. No Cloak
  dependency: `:crypto` is enough for one field.
  """

  @aad "you.identity_providers.client_secret"

  @doc """
  Encrypts `plaintext`, returning an opaque binary (random IV + auth tag +
  ciphertext) suitable for the `client_secret` column.
  """
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @doc """
  Decrypts a binary produced by `encrypt/1`. Returns the plaintext secret.
  Raises `MatchError` if the ciphertext is malformed or the auth tag fails
  to verify (tampered or encrypted under a different key).
  """
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    plaintext =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false)

    case plaintext do
      plaintext when is_binary(plaintext) ->
        plaintext

      :error ->
        raise "identity provider client_secret failed to decrypt (wrong key or tampered ciphertext)"
    end
  end

  defp key do
    secret_key_base = Application.fetch_env!(:you, YouWeb.Endpoint)[:secret_key_base]
    :crypto.mac(:hmac, :sha256, secret_key_base, @aad)
  end
end
