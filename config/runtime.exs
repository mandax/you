import Config

if System.get_env("PHX_SERVER") do
  config :you, YouWeb.Endpoint, server: true
end

config :you, YouWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# In dev/test, honour PHX_HOST for generated URLs (magic-link emails, OIDC
# discovery) so links resolve over the LAN/Tailscale, not just localhost.
phx_host = System.get_env("PHX_HOST")

if config_env() != :prod and phx_host do
  config :you, YouWeb.Endpoint,
    url: [
      host: phx_host,
      port: String.to_integer(System.get_env("PORT", "4000")),
      scheme: "http"
    ]
end

# Sender address for transactional emails (magic links, 2FA codes, resets).
config :you, :mail_from, System.get_env("MAIL_FROM") || "no-reply@#{phx_host || "example.com"}"

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /data/you/prod.db
      """

  config :you, You.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :you, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :you, YouWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  smtp_host =
    System.get_env("SMTP_HOST") ||
      raise """
      environment variable SMTP_HOST is missing.
      For example: smtp.fastmail.com
      """

  smtp_auth =
    case {System.get_env("SMTP_USERNAME"), System.get_env("SMTP_PASSWORD")} do
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
           port: String.to_integer(System.get_env("SMTP_PORT", "587")),
           tls: :always
         ] ++ smtp_auth

  # Persistent JWT signing keys. Without this, You generates an ephemeral key
  # per boot and every token dies on restart. Generate a seed with:
  #   mix run -e ':crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false) |> IO.puts()'
  # Rotation: move the old kid:seed pair to JWT_PREVIOUS_KEYS (comma-separated)
  # and point JWT_KEY_ID/JWT_SIGNING_KEY at the new key; drop the old pair once
  # every token it signed has expired.
  if jwt_seed = System.get_env("JWT_SIGNING_KEY") do
    decode_seed = fn value ->
      case Base.url_decode64(value, padding: false) do
        {:ok, <<seed::binary-32>>} -> seed
        _ -> raise "JWT signing keys must be base64url-encoded 32-byte Ed25519 seeds"
      end
    end

    jwt_kid = System.get_env("JWT_KEY_ID") || "you-ed25519-v1"

    jwt_keys =
      System.get_env("JWT_PREVIOUS_KEYS", "")
      |> String.split(",", trim: true)
      |> Map.new(fn pair ->
        [prev_kid, prev_seed] = String.split(pair, ":", parts: 2)
        {prev_kid, JOSE.JWK.generate_key({:okp, :Ed25519, decode_seed.(prev_seed)})}
      end)
      |> Map.put(jwt_kid, JOSE.JWK.generate_key({:okp, :Ed25519, decode_seed.(jwt_seed)}))

    config :you, You.JWT, current_kid: jwt_kid, keys: jwt_keys
  else
    Logger.warning(
      "JWT_SIGNING_KEY not set — using an ephemeral signing key, tokens will not survive restarts"
    )
  end

  # Management REST API bearer token. Unset/empty disables the API (403).
  config :you, :api_token, System.get_env("API_TOKEN")

  # Plausible-compatible analytics. Both must be set, or nothing is emitted.
  case {System.get_env("ANALYTICS_SRC"), System.get_env("ANALYTICS_DOMAIN")} do
    {src, domain} when is_binary(src) and is_binary(domain) ->
      config :you, :analytics, src: src, domain: domain

    _ ->
      :ok
  end

  config :wax_,
    origin: "https://#{host}",
    rp_id: :auto
end
