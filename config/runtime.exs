import Config

require Logger

if System.get_env("PHX_SERVER") do
  config :you, YouWeb.Endpoint, server: true
end

# Blank counts as unset. Compose substitutes an unset `${VAR}` as an empty
# string, so every variable a compose file mentions is always *present* in the
# container — reading them with `System.get_env/1` alone would configure an
# empty SMTP username or an empty From address rather than falling back.
env = fn name ->
  case System.get_env(name) do
    nil ->
      nil

    value ->
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end
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

# Deployment mode. `single` provisions one app from the environment on boot and
# hides the multi-app surface; anything else is the default fleet deployment.
# It is a runtime flag over the same schema: flipping it is a restart, not a
# migration.
if env.("YOU_MODE") == "single" do
  config :you, :mode, :single

  config :you, :single_app,
    slug: env.("SINGLE_APP_SLUG") || "app",
    name: env.("SINGLE_APP_NAME"),
    callback_url: env.("SINGLE_APP_CALLBACK_URL"),
    launch_url: env.("SINGLE_APP_LAUNCH_URL")
else
  config :you, :mode, :multi
end

if config_env() == :prod do
  database_path =
    env.("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /data/you/prod.db
      """

  config :you, You.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # Secrets are generated on first boot and persisted beside the database, so a
  # published compose file never has to ship one. A baked-in default would mean
  # every install on earth shares a signing key.
  #
  # The environment still wins where it is set: an operator who manages secrets
  # outside the volume keeps doing that, and the generated file is ignored.
  #
  # Generation has to survive two *processes* racing it. `runtime.exs` is
  # evaluated by every `bin/you eval` and `bin/you rpc` invocation in its own
  # VM, and the documented first-boot sequence runs one of those against a
  # container that has just started — so a plain read-then-write would let the
  # second process overwrite the key the first is already signing with, and
  # every token and session would die at the next restart. The write is made
  # exclusive via a hard link, which either wins or tells us someone else did:
  # the loser reads the winner's value instead of clobbering it.
  #
  # The secret is never in a world-readable file, not even briefly: the
  # temporary file is created empty, narrowed to 0600, and only then written.
  # `/data/you` is world-writable in the image (any UID can own the volume).
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

      # Random, not `System.unique_integer/1`: that is unique within a VM, and
      # this race is *between* VMs, where fresh nodes hand out the same values.
      # Two processes picking the same temp name defeats the whole scheme —
      # once the winner has linked it, the loser's write lands inside the
      # published file rather than beside it.
      tmp = "#{path}.#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}.tmp"

      try do
        File.touch!(tmp)
        File.chmod!(tmp, 0o600)
        secret = generate.()
        File.write!(tmp, secret <> "\n")

        case :file.make_link(tmp, path) do
          :ok ->
            secret

          # Another process generated one between the check and the link. Its
          # value is the one the instance is already using.
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

  # https on a real host is the deployment this is built for, and the default.
  # `PHX_SCHEME=http` exists for one case: evaluating the image on localhost
  # before there is a domain or a certificate. Without it every generated URL
  # — magic links, OIDC discovery, the links in the fallback mailbox — comes
  # out as https://localhost and cannot be opened, which breaks exactly the
  # flows the mailbox exists to let people try.
  scheme = env.("PHX_SCHEME") || "https"
  default_url_port = if scheme == "https", do: "443", else: "80"
  url_port = String.to_integer(env.("PHX_URL_PORT") || default_url_port)

  # A session cookie marked `secure` is not sent over http at all, so this
  # follows the scheme rather than being pinned on. Over https it means the
  # cookie cannot leak to a plaintext request to the same host before
  # `force_ssl` gets a chance to redirect.
  config :you, :secure_cookies, scheme == "https"

  config :you, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :you, YouWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # Email is load-bearing: magic links, email 2FA, confirmation and password
  # reset all go through it. Without SMTP those flows are visibly broken with
  # no obvious cause, so an unconfigured instance falls back to an in-memory
  # mailbox readable by admins at /console/mailbox rather than dropping mail on
  # the floor. It is an evaluation aid — `You.Mailer.production_ready?/0` stays
  # false and the console says so.
  case env.("SMTP_HOST") do
    smtp_host when is_binary(smtp_host) ->
      smtp_auth =
        case {env.("SMTP_USERNAME"), env.("SMTP_PASSWORD")} do
          {username, password} when is_binary(username) and is_binary(password) ->
            [username: username, password: password, auth: :always]

          _ ->
            []
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
      config :swoosh, local: true
      config :you, :mail_transport, :local

      Logger.warning(
        "SMTP_HOST not set — mail is being kept in an in-memory mailbox at /console/mailbox. " <>
          "Configure SMTP before treating this instance as production."
      )
  end

  # Persistent JWT signing keys. Generated on first boot and persisted beside
  # the database if unset — an ephemeral key would kill every issued token on
  # restart, silently. Generate one yourself with:
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

  # Management REST API bearer token. Unset/empty disables the API (403).
  config :you, :api_token, env.("API_TOKEN")

  # Plausible-compatible analytics. Both must be set, or nothing is emitted.
  # Blank counts as unset: compose substitutes an unset ${VAR} as an empty
  # string, so the variables are always present in the container.
  analytics_env =
    ["ANALYTICS_SRC", "ANALYTICS_DOMAIN"]
    |> Enum.map(&(System.get_env(&1, "") |> String.trim()))

  case analytics_env do
    [src, domain] when src != "" and domain != "" ->
      config :you, :analytics, src: src, domain: domain

    _ ->
      :ok
  end

  # Passkeys bind to an exact origin, so this has to track the scheme and port
  # the browser actually used. `http://localhost` is a secure context, so
  # passkeys work while evaluating locally; `http://` on any other host is not,
  # and the browser will refuse regardless of what we put here.
  config :wax_,
    origin: "#{scheme}://#{host}#{if url_port in [80, 443], do: "", else: ":#{url_port}"}",
    rp_id: :auto
end
