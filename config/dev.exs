import Config

# Address the dev endpoint binds to. Loopback unless BIND_IP says otherwise —
# set BIND_IP=0.0.0.0 to reach the dev server from another machine on the LAN.
# Dev has no auth on the admin unless configured, so only expose on trusted nets.
#
# Reaching the dev server by a LAN IP or Tailscale hostname also needs
# PHX_HOST set to that same address: `check_origin` (`config/config.exs`)
# now checks every environment's WebSocket handshake against
# `You.Hosting.own_host?/1`, which is `YouWeb.Endpoint.host/0` — i.e.
# PHX_HOST — unless per-app hostnames are configured. Visiting the page over
# BIND_IP=0.0.0.0 without also setting PHX_HOST renders static markup and
# then never connects a LiveView socket, the exact failure #121's
# `check_origin` fix exists to prevent on an app host.
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
  pool_size: 5,
  busy_timeout: 5_000,
  default_transaction_mode: :immediate

# For development, we disable any cache and enable
# debugging and code reloading.
config :you, YouWeb.Endpoint,
  http: [ip: bind_ip],
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "/IDzX034gJzQ59Uip5jFFMqOSZp5Lkgds2vm1W/1YlvJ9zqeofy3xmnj0JnDPltr",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:you, ~w(--sourcemap=inline --watch)]},
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

# Management REST API bearer token (dev only — set API_TOKEN in prod)

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :swoosh, :api_client, false

config :wax_, origin: "http://localhost:4000", rp_id: "localhost"
