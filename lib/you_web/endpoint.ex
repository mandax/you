defmodule YouWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :you

  @session_options [
    store: :cookie,
    key: "_you_key",
    signing_salt: "fn1jWGo5",
    same_site: "Lax"
  ]

  @doc """
  Session cookie options, resolved at boot rather than at compile time.

  `secure` has to follow the scheme the instance is actually served on, and
  that is only known at runtime: the same image runs behind TLS in production
  and on plain `http://localhost` while someone is evaluating it. Compiling
  the flag in would either ship a session cookie a browser refuses to store
  over http, or ship one that leaks over it.

  `config/runtime.exs` sets `:secure_cookies` from `PHX_SCHEME`.
  """
  def session_options do
    Keyword.put(@session_options, :secure, Application.get_env(:you, :secure_cookies, false))
  end

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {__MODULE__, :session_options, []}]],
    longpoll: [connect_info: [session: {__MODULE__, :session_options, []}]]

  plug Plug.Static,
    at: "/",
    from: :you,
    gzip: not code_reloading?,
    only: YouWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :you
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug :session
  plug YouWeb.Router

  # Plugs are initialised at compile time in production, so `Plug.Session` gets
  # its options through a wrapper that resolves them once on the first request
  # and caches them. Re-initialising per request would put the store's setup on
  # the hot path for every hit.
  defp session(conn, _opts), do: Plug.Session.call(conn, session_plug_opts())

  defp session_plug_opts do
    case :persistent_term.get({__MODULE__, :session}, nil) do
      nil ->
        opts = Plug.Session.init(session_options())
        :persistent_term.put({__MODULE__, :session}, opts)
        opts

      opts ->
        opts
    end
  end
end
