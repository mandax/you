import Config

# Address the dev endpoint binds to. Loopback unless BIND_IP says otherwise —
# set BIND_IP=0.0.0.0 to reach the dev server from another machine on the LAN.
# Dev has no auth on the admin unless configured, so only expose on trusted nets.
bind_ip =
  System.get_env("BIND_IP", "127.0.0.1")
  |> String.to_charlist()
  |> :inet.parse_address()
  |> case do
    {:ok, address} -> address
    {:error, :einval} -> raise "BIND_IP is not a valid IP address"
  end

# Configure your database
config :you, You.Repo,
  database: "priv/repo/you_dev.db",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 5

# For development, we disable any cache and enable
# debugging and code reloading.
config :you, YouWeb.Endpoint,
  http: [ip: bind_ip],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "/IDzX034gJzQ59Uip5jFFMqOSZp5Lkgds2vm1W/1YlvJ9zqeofy3xmnj0JnDPltr",
  watchers: [
    npx: [
      "tailwindcss",
      "-i",
      "assets/css/app.css",
      "-o",
      "priv/static/assets/css/app.css",
      "--watch",
      cd: Path.expand("..", __DIR__)
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :you, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :swoosh, :api_client, false
