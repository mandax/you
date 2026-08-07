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
  # "www.example.com" is `Plug.Adapters.Test.Conn`'s own hardcoded default
  # for a conn built with no explicit host — pinning the canonical host to
  # exactly that value means a test that never touches `conn.host` arrives
  # on what `You.Hosting.canonical?/1` (#121) actually recognises as
  # canonical, the same way it would in a real deployment where PHX_HOST is
  # a real, single value every ordinary request matches. Also a subdomain of
  # the wax_ `rp_id` below, so it satisfies `You.WebAuthn.
  # available_for_host?/1` too — the two checks agreeing on the suite's own
  # default host is what this value is for, not a coincidence to preserve.
  # Tests exercising a *different* host (a forged one, an app host, one
  # outside the RP ID's zone) already set `conn.host` explicitly.
  url: [host: "www.example.com"],
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

# A real canonical shape (origin's host equals the RP ID) rather than the
# unrelated localhost:4002 this used to pair with rp_id against — that
# mismatch is what a deployment never has, and pairing them for real is what
# lets a full Wax.register/3 ceremony (test/you/web_authn_origin_test.exs)
# actually exercise origin verification, not just the host-suffix gate.
# ConnTest's default request host ("www.example.com") is a subdomain of
# "example.com" — see the endpoint's `:url` above for why that default is
# also this instance's canonical host, not merely a qualifying one.
config :wax_, origin: "https://example.com", rp_id: "example.com"

# No network in tests — the Pwned Passwords check is exercised via its pure parser.
config :you, check_pwned_passwords: false

# Off by default so the whole suite doesn't share a 127.0.0.1 bucket;
# the rate-limit tests set their own limits.
config :you, YouWeb.RateLimit, %{}

# The sandbox rolls each test's writes back without the cache hearing about
# it, so settings are read straight from the database under test.
config :you, :settings_cache, false
config :you, :mode_app_cache, false
