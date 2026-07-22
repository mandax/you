import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

config :you, You.Repo,
  database: "priv/repo/you_test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :you, YouWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "0zeFpEgIJy43yfWqEBHzCOlVLR5L4FVNJyQ2ZaJsZ0vDXS3USpfEtM2sp1bNeTj8",
  server: false

config :you, You.Mailer, adapter: Swoosh.Adapters.Test

config :swoosh, :api_client, false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix,
  sort_verified_routes_query_params: true

config :you, :audit, enabled: false
config :you, :audit_webhook_url, nil

config :wax_, origin: "http://localhost:4002", rp_id: :auto

# No network in tests — the Pwned Passwords check is exercised via its pure parser.
config :you, check_pwned_passwords: false
