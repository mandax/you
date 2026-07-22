defmodule You.Audit.Streamer do
  @moduledoc """
  Streams audit events to a configured webhook URL.

  Attaches to `[:you, :audit, ...]` telemetry events and, when
  `config :you, :audit_webhook_url` is set to a non-empty string,
  POSTs them as JSON to that URL. Fire-and-forget — failures are
  logged but never affect the application.

  Disabled by default (config value is `nil`). Enable by setting:

      config :you, :audit_webhook_url, "https://hooks.example.com/audit"
  """

  use GenServer
  require Logger

  @events [
    [:you, :audit, :login, :attempt],
    [:you, :audit, :login, :totp],
    [:you, :audit, :admin, :action],
    [:you, :audit, :token, :exchange],
    [:you, :audit, :token, :revoke],
    [:you, :audit, :token, :refresh],
    [:you, :audit, :account, :update],
    [:you, :audit, :consent, :grant],
    [:you, :audit, :consent, :revoke]
  ]

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
      @events,
      &handle_event/4,
      :no_config
    )

    {:ok, %{}}
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
      event: event_name |> Enum.drop(2) |> Enum.join(":"),
      measurements: measurements,
      metadata: metadata,
      at: DateTime.to_iso8601(timestamp)
    }
  end

  @doc false
  def handle_event(event_name, measurements, metadata, _config) do
    Task.start(fn ->
      url = Application.get_env(:you, :audit_webhook_url)

      if is_binary(url) and url != "" do
        payload = build_payload(event_name, measurements, metadata)
        send_webhook(url, payload)
      end
    end)

    :ok
  end

  defp send_webhook(url, payload) do
    case Req.post(url,
           json: payload,
           receive_timeout: 5_000,
           retry: :never
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("[Audit.Streamer] webhook returned #{status} for #{payload[:event]}")

      {:error, reason} ->
        Logger.warning("[Audit.Streamer] webhook failed for #{payload[:event]}: #{inspect(reason)}")
    end
  end
end
