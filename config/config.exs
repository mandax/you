# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :you, :scopes,
  user: [
    default: true,
    module: You.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: You.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :you,
  ecto_repos: [You.Repo],
  generators: [timestamp_type: :utc_datetime],
  audit_webhook_url: nil,
  oidc_providers: %{}

# Configure the endpoint
#
# `check_origin` is an MFA rather than a static list: the WebSocket
# handshake's Origin has to be checked against the same "is this one of
# You's own hosts" answer everywhere else uses (`You.Hosting`), or an app
# host recognised for branding but not for sockets — or the reverse — is
# exactly the kind of drift #120's review spent three rounds eliminating.
# Never `false`: that disables CSWSH protection outright rather than
# widening who it's checked against. See `You.Hosting.check_origin?/1`.
config :you, YouWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  check_origin: {You.Hosting, :check_origin?, []},
  render_errors: [
    formats: [html: YouWeb.ErrorHTML, json: YouWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: You.PubSub,
  live_view: [signing_salt: "pOOjL5Ii"]

# Rate limits for credential-verifying endpoints: {max attempts, window in
# milliseconds} per remote IP. Read at request time — override per
# environment or in runtime.exs without recompiling. A map (not a keyword
# list) so environments can replace the whole set instead of deep-merging.
config :you, YouWeb.RateLimit, %{
  login: {5, 60_000},
  registration: {5, 60_000},
  password_reset: {3, 60_000},
  totp: {10, 60_000},
  email_2fa: {10, 60_000},
  headless_login: {5, 60_000},
  headless_register: {5, 60_000},
  oauth_token: {10, 60_000},
  api_mgmt: {120, 60_000},
  # Unlike every limit above, `/auth/:provider` verifies no credential — the
  # goal here is only to bound how fast an anonymous GET can write flow rows,
  # not to slow down guessing. A NAT'd office shares one bucket (the client
  # IP trust problem is #141's, not re-solved here), so this is set high
  # enough that a shared IP doing ordinary sign-ins doesn't get a bare 429 on
  # a browser navigation, while still bounding a sustained anonymous flood.
  social_login: {60, 60_000}
}

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :you, You.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  you: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Never log request params under these keys — most importantly the bundle
# password on `POST /console/backup/export`, which decrypts every secret a
# config bundle carries.
config :phoenix, :filter_parameters, ["password", "secret", "token"]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# The extension a sealed configuration bundle downloads with
# (`YouWeb.ConsoleBackupController.export/2`), so the console's import upload
# can restrict its file picker to it.
config :mime, :types, %{"application/octet-stream" => ["you-bundle"]}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
