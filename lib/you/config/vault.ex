defmodule You.Config.Vault do
  @moduledoc """
  Password-based encryption for configuration bundles.

  A bundle carries client secrets, webhook signing secrets and upstream
  provider credentials, so it is never written in the clear. The password is
  the only key: bundles are meant to be imported into a *different* instance,
  which shares no `secret_key_base` with the one that wrote them, so nothing
  instance-derived can be used here.

  The envelope is JSON with base64 fields rather than an opaque blob, so an
  operator can see the format and KDF parameters of a file they are asked to
  keep. Only the payload is secret.
  """

  @format "you.config.v1"
  @iterations 600_000
  @digest :sha256
  @min_password_length 12

  @doc "The shortest password `seal/2` will accept."
  def min_password_length, do: @min_password_length

  @doc """
  Encrypts `payload` under `password`, returning the JSON envelope as a string.

  Raises `ArgumentError` for a password shorter than `min_password_length/0`.
  A bundle carries every secret the instance holds — SMTP credentials, the
  management API token, webhook signing secrets, upstream provider client
  secrets — and 600k PBKDF2 iterations do not rescue a short password. This
  holds for every caller, not just the console's export form.
  """
  def seal(payload, password) when is_map(payload) and is_binary(password) do
    if String.length(password) < @min_password_length do
      raise ArgumentError,
            "bundle password must be at least #{@min_password_length} characters"
    end

    salt = :crypto.strong_rand_bytes(16)
    iv = :crypto.strong_rand_bytes(12)
    key = derive(password, salt)

    header = %{
      "format" => @format,
      "kdf" => %{"algorithm" => "pbkdf2-hmac-sha256", "iterations" => @iterations},
      "salt" => Base.encode64(salt),
      "iv" => Base.encode64(iv)
    }

    plaintext = Jason.encode!(payload)
    aad = Jason.encode!(header)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)

    header
    |> Map.put("tag", Base.encode64(tag))
    |> Map.put("payload", Base.encode64(ciphertext))
    |> Jason.encode!(pretty: true)
  end

  @doc """
  Decrypts an envelope produced by `seal/2`.

  Returns `{:ok, payload}`, `{:error, :wrong_password}` when authentication
  fails, or `{:error, :malformed}` for anything that is not a bundle. A wrong
  password and a tampered file are indistinguishable by design — GCM
  authenticates the whole envelope, including the KDF parameters, so neither
  can be altered without failing.
  """
  def open(envelope, password) when is_binary(envelope) and is_binary(password) do
    with {:ok, json} <- decode_json(envelope),
         {:ok, parts} <- parts(json),
         {:ok, plaintext} <- decrypt(parts, password),
         {:ok, payload} <- decode_json(plaintext) do
      {:ok, payload}
    end
  end

  defp parts(
         %{"format" => @format, "salt" => salt, "iv" => iv, "tag" => tag, "payload" => payload} =
           json
       ) do
    with {:ok, salt} <- Base.decode64(salt),
         {:ok, iv} <- Base.decode64(iv),
         {:ok, tag} <- Base.decode64(tag),
         {:ok, ciphertext} <- Base.decode64(payload),
         iterations when is_integer(iterations) <- get_in(json, ["kdf", "iterations"]) do
      aad = json |> Map.drop(["tag", "payload"]) |> Jason.encode!()

      {:ok,
       %{salt: salt, iv: iv, tag: tag, ciphertext: ciphertext, aad: aad, iterations: iterations}}
    else
      _ -> {:error, :malformed}
    end
  end

  defp parts(_json), do: {:error, :malformed}

  defp decrypt(parts, password) do
    key = derive(password, parts.salt, parts.iterations)

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           parts.iv,
           parts.ciphertext,
           parts.aad,
           parts.tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :wrong_password}
    end
  end

  defp decode_json(binary) do
    case Jason.decode(binary) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :malformed}
    end
  end

  defp derive(password, salt, iterations \\ @iterations) do
    :crypto.pbkdf2_hmac(@digest, password, salt, iterations, 32)
  end
end
