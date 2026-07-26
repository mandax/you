import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

config :you, You.Repo,
  database: "priv/repo/you_test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # SQLite serializes writers; under async load a blocked writer otherwise
  # errors immediately with "Database busy". Wait for the lock instead.
  busy_timeout: 5_000,
  journal_mode: :wal,
  # `busy_timeout` alone is not enough: the sandbox wraps each test in a
  # transaction that starts as a reader, and SQLite refuses to invoke the busy
  # handler when such a transaction later needs to upgrade to a writer (waiting
  # there could deadlock two readers). It returns SQLITE_BUSY immediately, which
  # is the flake CI hits. `:immediate` takes the write lock at BEGIN, where the
  # busy handler does apply, so a blocked test waits instead of failing.
  default_transaction_mode: :immediate

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

# Off by default so the whole suite doesn't share a 127.0.0.1 bucket;
# the rate-limit tests set their own limits.
config :you, YouWeb.RateLimit, %{}

# Management REST API bearer token
config :you, :api_token, "test-api-token"
