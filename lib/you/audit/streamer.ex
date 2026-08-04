defmodule You.Audit.Streamer do
  @moduledoc """
  Streams audit events to a configured webhook URL.

  Attaches to `[:you, :audit, ...]` telemetry events and, when
  `config :you, :audit_webhook_url` is set to a non-empty string,
  POSTs them as JSON to that URL. Fire-and-forget: failures are
  logged but never affect the application.

  Disabled by default (config value is `nil`). Enable by setting:

      config :you, :audit_webhook_url, "https://hooks.example.com/audit"
  """

  use GenServer
  require Logger

  @doc """
  Starts the streamer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :telemetry.attach_many(
      "you-audit-streamer",
      You.Webhooks.telemetry_events(),
      &handle_event/4,
      :no_config
    )

    # Load the webhook setting after init returns, so a DB/settings hiccup at
    # boot degrades gracefully instead of crashing the streamer.
    {:ok, %{recent: []}, {:continue, :reload}}
  end

  @impl true
  def handle_continue(:reload, state) do
    reload()
    {:noreply, state}
  end

  @max_recent 100

  @doc """
  Returns the most recent audit events (newest first), capped at #{@max_recent}.

  In-memory only: this is a live activity view, not a durable log. Durable
  retention is the job of the outbound webhook (`reload/0`).

  Degrades to `[]` if the streamer process is unavailable; a live activity
  view must never take down the page that shows it.
  """
  def recent do
    GenServer.call(__MODULE__, :recent)
  catch
    :exit, _ -> []
  end

  @doc """
  Refreshes the active webhook URL from the `:audit_webhook_url` instance
  setting into fast config env. Call after the setting changes so the
  per-event hot path never touches the database.

  Falls back to the compile-time `config :you, :audit_webhook_url` when the
  setting is blank.
  """
  def reload do
    url =
      try do
        case You.Settings.get(:audit_webhook_url) do
          v when is_binary(v) and v != "" -> v
          _ -> Application.get_env(:you, :audit_webhook_url)
        end
      rescue
        _ -> Application.get_env(:you, :audit_webhook_url)
      end

    Application.put_env(:you, :audit_webhook_url, url)
    :ok
  end

  @doc """
  Builds the webhook payload for an audit event.

  Returns a map with `event`, `measurements`, `metadata`, and `at` keys.

  ## Examples

      iex> You.Audit.Streamer.build_payload([:you, :audit, :login, :attempt], %{}, %{user_id: 1}, ~U[2026-07-22 12:00:00Z])
      %{event: "login:attempt", measurements: %{}, metadata: %{user_id: 1}, at: "2026-07-22T12:00:00Z"}

  """
  def build_payload(event_name, measurements, metadata, timestamp \\ DateTime.utc_now()) do
    %{
      event: You.Webhooks.event_type(event_name),
      measurements: measurements,
      metadata: metadata,
      at: DateTime.to_iso8601(timestamp)
    }
  end

  @doc false
  def handle_event(event_name, measurements, metadata, _config) do
    payload = build_payload(event_name, measurements, metadata)
    GenServer.cast(__MODULE__, {:record, payload})

    url = Application.get_env(:you, :audit_webhook_url)

    if is_binary(url) and url != "" do
      Task.start(fn -> send_webhook(url, payload) end)
    end

    :ok
  end

  @impl true
  def handle_call(:recent, _from, state) do
    {:reply, state.recent, state}
  end

  @impl true
  def handle_cast({:record, payload}, state) do
    {:noreply, %{state | recent: Enum.take([payload | state.recent], @max_recent)}}
  end

  defp send_webhook(url, payload) do
    case Req.post(url,
           json: payload,
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("[Audit.Streamer] webhook returned #{status} for #{payload[:event]}")

      {:error, reason} ->
        Logger.warning(
          "[Audit.Streamer] webhook failed for #{payload[:event]}: #{inspect(reason)}"
        )
    end
  end
end
