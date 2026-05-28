import Config

# Configure your database
config :you, You.Repo,
  database: "priv/repo/you_dev.db",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 5

# For development, we disable any cache and enable
# debugging and code reloading.
config :you, YouWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "/IDzX034gJzQ59Uip5jFFMqOSZp5Lkgds2vm1W/1YlvJ9zqeofy3xmnj0JnDPltr"

# Enable dev routes for dashboard and mailbox
config :you, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :swoosh, :api_client, false
