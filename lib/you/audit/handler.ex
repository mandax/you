defmodule You.Audit.Handler do
  @moduledoc """
  Telemetry handler that writes audit events to JSONL files.

  Attaches to `[:you, :audit, category, action]` events and writes
  one JSON line per event to `log_dir/{category}.jsonl`.

  The log directory is configured via:

      config :you, :audit, log_dir: "/var/log/you"

  Defaults to `priv/log` in dev/test.
  """

  use GenServer

  @category_map %{
    login: "login",
    admin: "admin",
    token: "token",
    account: "account",
    consent: "consent"
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    log_dir = Keyword.get(opts, :log_dir, log_dir_from_config())
    File.mkdir_p!(log_dir)
    :persistent_term.put({__MODULE__, :log_dir}, log_dir)

    :telemetry.attach_many(
      "you-audit-handler",
      [
        [:you, :audit, :login, :attempt],
        [:you, :audit, :login, :totp],
        [:you, :audit, :admin, :action],
        [:you, :audit, :token, :exchange],
        [:you, :audit, :token, :revoke],
        [:you, :audit, :account, :update],
        [:you, :audit, :consent, :grant],
        [:you, :audit, :consent, :revoke]
      ],
      &handle_event/4,
      :no_config
    )

    {:ok, %{log_dir: log_dir}}
  end

  def handle_event([:you, :audit, category, action], _measurements, metadata, _config) do
    filename = Map.get(@category_map, category, "other")
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    event =
      metadata
      |> Map.put(:ts, ts)
      |> Map.put(:event, "#{category}:#{action}")

    line = Jason.encode!(event) <> "\n"

    log_dir = :persistent_term.get({__MODULE__, :log_dir})
    file_path = Path.join(log_dir, "#{filename}.jsonl")
    File.write!(file_path, line, [:append])
  end

  defp log_dir_from_config do
    Application.get_env(:you, :audit, [])[:log_dir] || "priv/log"
  end
end
