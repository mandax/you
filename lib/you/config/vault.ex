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

  New envelopes are sealed with Argon2id. `m_cost` is capped at 16 (64 MiB)
  deliberately, not left at whatever the library defaults to: this runs
  during disaster recovery as often as it runs during a routine export, and
  that is exactly when an operator's box is most likely to be a small VPS
  under memory pressure and least likely to have anyone around who can
  debug an OOM. Memory is the parameter with a failure mode, so it stays
  conservative. `t_cost` has no such failure mode — it only costs wall
  clock on an action a human performs once and deliberately waits for — so
  it is raised instead, to 16, to spend the rest of the "a second or two"
  budget this KDF is allowed. Do not lower `t_cost` to "speed this up":
  that is the whole point of raising it. If `m_cost` ever needs to change,
  raise it only with headroom for constrained hardware in mind; `t_cost`
  has no such constraint and can be raised freely.
  """

  @format "you.config.v1"
  @max_pbkdf2_iterations 2_000_000
  @digest :sha256

  @argon2_m_cost 16
  @argon2_t_cost 16
  @argon2_parallelism 4
  @argon2_type 2
  @max_argon2_m_cost 20
  @max_argon2_t_cost 32
  @max_argon2_parallelism 8

  @min_password_length 12

  @doc "The shortest password `seal/2` will accept."
  def min_password_length, do: @min_password_length

  @doc """
  Encrypts `payload` under `password`, returning the JSON envelope as a string.

  Raises `ArgumentError` for a password shorter than `min_password_length/0`.
  A bundle carries every secret the instance holds — SMTP credentials, the
  management API token, webhook signing secrets, upstream provider client
  secrets — and no amount of KDF cost rescues a short password. This holds
  for every caller, not just the console's export form.

  New envelopes are always sealed with Argon2id: it is memory-hard, which
  removes most of the advantage a GPU or ASIC gives an attacker against an
  offline copy of a bundle. `open/2` still understands envelopes sealed with
  the older PBKDF2-HMAC-SHA256 KDF, dispatching on the `"kdf"` header field.
  """
  def seal(payload, password) when is_map(payload) and is_binary(password) do
    if String.length(password) < @min_password_length do
      raise ArgumentError,
            "bundle password must be at least #{@min_password_length} characters"
    end

    salt = :crypto.strong_rand_bytes(16)
    iv = :crypto.strong_rand_bytes(12)

    key =
      derive_argon2id(password, salt, @argon2_m_cost, @argon2_t_cost, @argon2_parallelism)

    header = %{
      "format" => @format,
      "kdf" => %{
        "algorithm" => "argon2id",
        "m_cost" => @argon2_m_cost,
        "t_cost" => @argon2_t_cost,
        "parallelism" => @argon2_parallelism
      },
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
         {:ok, kdf} <- valid_kdf(json["kdf"]) do
      aad = json |> Map.drop(["tag", "payload"]) |> Jason.encode!()

      {:ok, %{salt: salt, iv: iv, tag: tag, ciphertext: ciphertext, aad: aad, kdf: kdf}}
    else
      _ -> {:error, :malformed}
    end
  end

  defp parts(_json), do: {:error, :malformed}

  # Matches on a map so a non-map `"kdf"` (a string, a list, absent
  # entirely) fails every clause instead of raising: a bare
  # `json["kdf"]["iterations"]` used to raise `FunctionClauseError` the
  # moment `"kdf"` itself was not a map. Every numeric field is bounded
  # before it reaches a KDF: an unbounded iteration count is a
  # CPU-exhaustion DoS and an unbounded `m_cost` is a memory-exhaustion
  # DoS, both from a file an admin merely opened for preview, before any
  # password has been checked. The tagged tuple this returns is what the
  # derive functions dispatch on.
  defp valid_kdf(%{"algorithm" => "pbkdf2-hmac-sha256", "iterations" => iterations})
       when is_integer(iterations) and iterations > 0 and iterations <= @max_pbkdf2_iterations do
    {:ok, {:pbkdf2, iterations}}
  end

  defp valid_kdf(%{
         "algorithm" => "argon2id",
         "m_cost" => m_cost,
         "t_cost" => t_cost,
         "parallelism" => parallelism
       })
       when is_integer(m_cost) and m_cost > 0 and m_cost <= @max_argon2_m_cost and
              is_integer(t_cost) and t_cost > 0 and t_cost <= @max_argon2_t_cost and
              is_integer(parallelism) and parallelism > 0 and
              parallelism <= @max_argon2_parallelism do
    {:ok, {:argon2id, m_cost, t_cost, parallelism}}
  end

  defp valid_kdf(_kdf), do: :error

  defp decrypt(parts, password) do
    key = derive(password, parts.salt, parts.kdf)

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

  defp derive(password, salt, {:pbkdf2, iterations}) do
    :crypto.pbkdf2_hmac(@digest, password, salt, iterations, 32)
  end

  defp derive(password, salt, {:argon2id, m_cost, t_cost, parallelism}) do
    derive_argon2id(password, salt, m_cost, t_cost, parallelism)
  end

  defp derive_argon2id(password, salt, m_cost, t_cost, parallelism) do
    hex =
      Argon2.Base.hash_password(password, salt,
        t_cost: t_cost,
        m_cost: m_cost,
        parallelism: parallelism,
        hashlen: 32,
        argon2_type: @argon2_type,
        format: :raw_hash
      )

    Base.decode16!(hex, case: :lower)
  end
end
