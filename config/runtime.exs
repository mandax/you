import Config

require Logger

if System.get_env("PHX_SERVER") do
  config :you, YouWeb.Endpoint, server: true
end

# Blank counts as unset: compose substitutes an unset `${VAR}` as an empty
# string, so every variable it mentions is always present in the container.
env = fn name ->
  case name |> System.get_env("") |> String.trim() do
    "" -> nil
    value -> value
  end
end

config :you, YouWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# In dev/test, honour PHX_HOST for generated URLs (magic-link emails, OIDC
# discovery) so links resolve over the LAN/Tailscale, not just localhost.
phx_host = env.("PHX_HOST")

if config_env() != :prod and phx_host do
  config :you, YouWeb.Endpoint,
    url: [
      host: phx_host,
      port: String.to_integer(System.get_env("PORT", "4000")),
      scheme: "http"
    ]
end

# Sender address for transactional emails (magic links, 2FA codes, resets).
config :you, :mail_from, env.("MAIL_FROM") || "no-reply@#{phx_host || "example.com"}"

# Attributes the single app is provisioned with on first boot. Seed data, not
# live configuration: the mode itself is the `you_mode` setting (seeded from
# YOU_MODE by You.Settings.EnvSeed), and the console owns the app row from the
# first boot onwards.
if env.("YOU_MODE") == "single" do
  config :you, :single_app,
    slug: env.("SINGLE_APP_SLUG") || "app",
    name: env.("SINGLE_APP_NAME"),
    callback_url: env.("SINGLE_APP_CALLBACK_URL"),
    launch_url: env.("SINGLE_APP_LAUNCH_URL")
end

if config_env() == :prod do
  database_path =
    env.("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /data/you/prod.db
      """

  # SQLite serialises writers. `:immediate` takes the write lock at BEGIN,
  # where the busy handler applies — a deferred transaction that upgrades from
  # read to write gets SQLITE_BUSY with no wait at all. config/test.exs carries
  # the same pair for the same reason.
  config :you, You.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    busy_timeout: String.to_integer(env.("BUSY_TIMEOUT_MS") || "5000"),
    default_transaction_mode: :immediate

  # Generated on first boot and persisted beside the database, so no compose
  # file ever ships a shared signing key. The environment still wins when set.
  #
  # `runtime.exs` runs in its own VM for every `bin/you eval` and `rpc`, so two
  # processes can race first boot: the write is published with a hard link, and
  # the loser reads the winner's value rather than clobbering it. The temp file
  # is narrowed to 0600 before the secret goes in.
  persisted_secret = fn name, generate ->
    dir = Path.dirname(database_path)
    path = Path.join(dir, name)

    read = fn ->
      case File.read(path) do
        {:ok, contents} ->
          String.trim(contents)

        {:error, reason} ->
          raise """
          could not read #{path}: #{:file.format_error(reason)}

          You persists generated secrets next to DATABASE_PATH. Either make that
          directory readable and writable, or set the secret in the environment.
          """
      end
    end

    if File.exists?(path) do
      read.()
    else
      File.mkdir_p!(dir)

      # Random, not `System.unique_integer/1`: that repeats across VMs, and a
      # shared temp name would put the loser's write inside the published file.
      tmp = "#{path}.#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}.tmp"

      try do
        File.touch!(tmp)
        File.chmod!(tmp, 0o600)
        secret = generate.()
        File.write!(tmp, secret <> "\n")

        case :file.make_link(tmp, path) do
          :ok ->
            secret

          # Another process won; its value is the one already in use.
          {:error, :eexist} ->
            read.()

          {:error, reason} ->
            raise """
            could not write #{path}: #{:file.format_error(reason)}

            You persists generated secrets next to DATABASE_PATH. Either make
            that directory writable, or set the secret in the environment.
            """
        end
      after
        File.rm(tmp)
      end
    end
  end

  secret_key_base =
    env.("SECRET_KEY_BASE") ||
      persisted_secret.("secret_key_base", fn ->
        :crypto.strong_rand_bytes(64) |> Base.encode64(padding: false)
      end)

  host = env.("PHX_HOST") || "example.com"

  # https unless told otherwise; `http` is for localhost or a private network.
  # Validated, not trusted: a typo would silently drop the `secure` cookie flag
  # on a deployment that is in fact behind TLS.
  scheme =
    case env.("PHX_SCHEME") || "https" do
      valid when valid in ["http", "https"] ->
        valid

      other ->
        raise """
        PHX_SCHEME must be "http" or "https", got: #{inspect(other)}

        Leave it unset unless You is served over plain http (localhost, or a
        private network). Getting it wrong drops the `secure` flag from the
        session cookie.
        """
    end

  default_url_port = if scheme == "https", do: "443", else: "80"
  url_port = String.to_integer(env.("PHX_URL_PORT") || default_url_port)

  # Follows the scheme: a `secure` cookie is not sent over http at all.
  config :you, :secure_cookies, scheme == "https"

  config :you, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :you, YouWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # No SMTP falls back to an in-memory mailbox at /console/mailbox rather than
  # dropping mail silently. `You.Mailer.production_ready?/0` stays false.
  #
  # Started regardless of whether SMTP is configured at boot: `You.Mailer`
  # switches adapters at send time from `You.Settings`, so an admin can clear
  # `smtp_host` in the console and fall back to this mailbox without a
  # restart. `config/prod.exs` compiles `local: false` in; without this, an
  # instance that booted with SMTP configured would have no storage process
  # to fall back to and delivery would crash instead of degrading.
  config :swoosh, local: true

  case env.("SMTP_HOST") do
    smtp_host when is_binary(smtp_host) ->
      smtp_auth =
        case {env.("SMTP_USERNAME"), env.("SMTP_PASSWORD")} do
          {u, p} when is_binary(u) and is_binary(p) -> [username: u, password: p, auth: :always]
          _ -> []
        end

      config :you,
             You.Mailer,
             [
               adapter: Swoosh.Adapters.SMTP,
               relay: smtp_host,
               port: String.to_integer(env.("SMTP_PORT") || "587"),
               tls: :always
             ] ++ smtp_auth

      config :you, :mail_transport, :smtp

    _ ->
      config :you, You.Mailer, adapter: Swoosh.Adapters.Local
      config :you, :mail_transport, :local

      Logger.warning(
        "SMTP_HOST not set — mail is being kept in an in-memory mailbox at /console/mailbox. " <>
          "Configure SMTP before treating this instance as production."
      )
  end

  # Persistent JWT signing keys, generated on first boot if unset — an
  # ephemeral key kills every issued token on restart. Generate one with:
  #   mix run -e ':crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false) |> IO.puts()'
  # Rotation: move the old kid:seed pair to JWT_PREVIOUS_KEYS (comma-separated)
  # and point JWT_KEY_ID/JWT_SIGNING_KEY at the new key; drop the old pair once
  # every token it signed has expired.
  jwt_seed =
    env.("JWT_SIGNING_KEY") ||
      persisted_secret.("jwt_signing_key", fn ->
        :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      end)

  decode_seed = fn value ->
    case Base.url_decode64(value, padding: false) do
      {:ok, <<seed::binary-32>>} -> seed
      _ -> raise "JWT signing keys must be base64url-encoded 32-byte Ed25519 seeds"
    end
  end

  jwt_kid = env.("JWT_KEY_ID") || "you-ed25519-v1"

  jwt_keys =
    System.get_env("JWT_PREVIOUS_KEYS", "")
    |> String.split(",", trim: true)
    |> Map.new(fn pair ->
      [prev_kid, prev_seed] = String.split(pair, ":", parts: 2)
      {prev_kid, JOSE.JWK.generate_key({:okp, :Ed25519, decode_seed.(prev_seed)})}
    end)
    |> Map.put(jwt_kid, JOSE.JWK.generate_key({:okp, :Ed25519, decode_seed.(jwt_seed)}))

  config :you, You.JWT, current_kid: jwt_kid, keys: jwt_keys

  # Passkeys bind to an exact origin, so the port is omitted only when it is
  # the scheme's default.
  webauthn_origin =
    "#{scheme}://#{host}#{if url_port == String.to_integer(default_url_port), do: "", else: ":#{url_port}"}"

  # WEBAUTHN_RP_ID pins the relying-party ID. `:auto` (the prior default)
  # derived it from this same origin, resolved per challenge but from this
  # boot-fixed config rather than the live request — `URI.parse(origin).host`,
  # i.e. PHX_HOST with any port stripped — so it moved silently whenever
  # PHX_HOST did, stranding every passkey with no warning. Unset reproduces
  # that exact derivation
  # (`URI.parse(webauthn_origin).host`, not the raw `host` binding above, so
  # a `PHX_HOST` that happens to carry a port still resolves the same way
  # `:auto` did), so a single-host deployment is unchanged. Environment-only
  # — see `You.Settings.forbidden_keys/0` — because changing it strands
  # every passkey already registered, in both directions; that is a
  # deployment operation with a maintenance window, not a console toggle.
  #
  # `origin_verify_fun` is deliberately not set here: `Wax.Challenge.new/1`
  # only pulls `@opt_names` out of this app's config
  # (`deps/wax_/lib/wax/challenge.ex`), which does not include
  # `origin_verify_fun` — set globally, it would be silently ignored. Every
  # `Wax.new_registration_challenge/1` and `Wax.new_authentication_challenge/1`
  # call passes `origin_verify_fun: {You.WebAuthn, :origin_matches?, []}`
  # explicitly instead (`YouWeb.WebAuthnController`).
  webauthn_rp_id = env.("WEBAUTHN_RP_ID") || URI.parse(webauthn_origin).host

  # A typo here (or a WEBAUTHN_RP_ID set for a hostname this instance no
  # longer answers to) makes every host, including the canonical one, fail
  # You.WebAuthn.available_for_host?/1 — passkeys vanish with no button, no
  # error, nothing to point at. This is the boot-time signal that gap would
  # otherwise have none of.
  #
  # Compared the same way available_for_host?/1 compares: downcased, one
  # trailing dot stripped, and against the *canonical* host
  # (`URI.parse(webauthn_origin).host`, matching what `conn.host` actually
  # carries) rather than the raw PHX_HOST binding, which — unusually, but
  # not incorrectly — may itself carry a port. Comparing the raw values
  # would warn on cases that work fine at runtime, and a warning an
  # instance can't ever silence except by "fixing" a config that was never
  # broken is worse than no warning.
  webauthn_normalize_host = fn h ->
    h = String.downcase(h)
    if String.ends_with?(h, "."), do: binary_part(h, 0, byte_size(h) - 1), else: h
  end

  webauthn_canonical_host = webauthn_normalize_host.(URI.parse(webauthn_origin).host)
  webauthn_rp_id_normalized = webauthn_normalize_host.(webauthn_rp_id)

  if webauthn_canonical_host != webauthn_rp_id_normalized and
       not String.ends_with?(webauthn_canonical_host, ".#{webauthn_rp_id_normalized}") do
    Logger.warning(
      "WEBAUTHN_RP_ID (#{webauthn_rp_id}) does not cover PHX_HOST (#{host}) — " <>
        "it must equal it or be a parent domain of it, or the canonical host will not offer passkeys."
    )
  end

  config :wax_,
    origin: webauthn_origin,
    rp_id: webauthn_rp_id
end
