import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

config :you, You.Repo,
  database: "priv/repo/you_test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # SQLite serializes writers; under async load a blocked writer otherwise
  # errors immediately with "Database busy". Wait for the lock instead.
  # Comfortably above the suite's own async phase, which is what a blocked
  # test waits on, but deliberately under Ecto's 15s default query timeout:
  # past that the caller raises DBConnection.ConnectionError while the busy
  # handler is still asleep inside the NIF, which is a worse failure than the
  # one being prevented.
  busy_timeout: 10_000,
  journal_mode: :wal,
  # This key does NOT affect the sandbox, contrary to what this comment used
  # to claim (#161). The diagnosis it recorded was right — a transaction that
  # begins as a reader and later upgrades to a writer gets SQLITE_BUSY with no
  # busy handler, because waiting there could deadlock two readers — but the
  # mitigation never reached the sandbox: `Ecto.Adapters.SQL.Sandbox`'s
  # `post_checkout/3` calls `handle_begin([mode: :transaction] ++ opts, ...)`,
  # and `Exqlite.Connection.handle_begin/2` reads `Keyword.get(options, :mode,
  # state.default_transaction_mode)` — so the hardcoded `:transaction` wins and
  # maps to a plain deferred `BEGIN TRANSACTION`. Nor does it apply to an
  # explicit `Repo.transaction/2` here: inside the sandbox that is a SAVEPOINT,
  # not a BEGIN. In the test environment this key governs nothing. The real fix is in
  # `You.DataCase.setup_sandbox/1`, which issues a write as the transaction's
  # first statement. Kept here for parity with dev/prod, where it does apply.
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
  #
  # The cost of pinning them together, stated so it is not rediscovered: a
  # test that *means* to exercise an unrecognised host but forgets to set
  # `conn.host` now silently passes on the canonical path instead. Before
  # this value matched, forcing `Hosting.enabled?/0` true reddened 288 tests
  # and now reddens 21 — but the 288 were mostly measuring "the suite's
  # default host is foreign", and ~40 of them were asserting branding on a
  # foreign host, which passed only because unrecognised hosts still branded.
  # The gate is now pinned by tests that name it rather than by that
  # coincidence. If you are writing an unrecognised-host test, set the host.
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

# Near-zero webhook retry backoff (#159). The dispatcher tests are about the
# retry *policy* — three attempts, then give up — not about how long a real
# deployment waits between them, and the production schedule
# ([0, 2_000, 10_000]) costs the suite ~12s of genuine sleeping. Non-zero so
# the `wait > 0` sleep branch is still exercised.
config :you, :webhook_retry_backoff, [0, 10, 10]

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
