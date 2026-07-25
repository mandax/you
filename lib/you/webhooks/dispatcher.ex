defmodule You.Webhooks.Dispatcher do
  @moduledoc """
  Delivers webhook payloads to subscribed endpoints.

  Attaches to the same `[:you, :audit, ...]` telemetry events as the audit
  streamer. Endpoints are cached in the GenServer state (refreshed via
  `reload/0` whenever `You.Webhooks` mutates them), so deliveries never
  touch the database on the hot path. Each endpoint gets its own delivery
  task with up to 3 attempts (immediate, +2s, +10s); a slow or failing
  endpoint never delays the others. Deliveries are not persisted — a
  restart drops in-flight retries.
  """
  use GenServer
  require Logger

  alias You.Webhooks

  @req_timeout 5_000
  @retry_backoff [0, 2_000, 10_000]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Refreshes the cached endpoints from the database. Called by
  `You.Webhooks` after every endpoint mutation; safe to call anytime.
  """
  def reload do
    if pid = Process.whereis(__MODULE__) do
      GenServer.call(pid, :reload)
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    :telemetry.attach_many(
      "you-webhooks-dispatcher",
      Webhooks.telemetry_events(),
      &__MODULE__.handle_event/4,
      :no_config
    )

    {:ok, %{endpoints: []}, {:continue, :reload}}
  end

  @impl true
  def handle_continue(:reload, state) do
    {:noreply, %{state | endpoints: Webhooks.list_endpoints()}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {:reply, :ok, %{state | endpoints: Webhooks.list_endpoints()}}
  end

  @doc false
  def handle_event(event_name, _measurements, metadata, _config) do
    event_type = Webhooks.event_type(event_name)

    Task.start(fn ->
      event_type
      |> subscribed()
      |> Enum.each(&Task.start(fn -> deliver(&1, event_type, metadata) end))
    end)

    :ok
  end

  defp subscribed(event_type) do
    case Process.whereis(__MODULE__) do
      nil ->
        []

      pid ->
        pid
        |> :sys.get_state()
        |> Map.get(:endpoints)
        |> Enum.filter(&(&1.enabled and event_type in &1.events))
    end
  end

  defp deliver(endpoint, event_type, data) do
    payload = %{
      id: "evt_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}",
      type: event_type,
      created: DateTime.to_iso8601(DateTime.utc_now()),
      data: data
    }

    body = Jason.encode!(payload)
    timestamp = DateTime.to_unix(DateTime.utc_now())

    signature =
      :hmac
      |> :crypto.mac(:sha256, endpoint.secret, "#{timestamp}.#{body}")
      |> Base.encode16(case: :lower)

    headers = [
      {"content-type", "application/json"},
      {"you-signature", "t=#{timestamp},v1=#{signature}"}
    ]

    case post_with_retries(endpoint.url, body, headers, @retry_backoff) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "webhook delivery to #{endpoint.url} failed after #{length(@retry_backoff)} attempts: #{inspect(reason)}"
        )
    end
  end

  defp post_with_retries(_url, _body, _headers, []), do: {:error, :attempts_exhausted}

  defp post_with_retries(url, body, headers, [wait | rest]) do
    if wait > 0, do: Process.sleep(wait)

    case Req.post(url, body: body, headers: headers, receive_timeout: @req_timeout) do
      {:ok, %{status: status}} when status in 200..299 -> {:ok, status}
      {:ok, %{status: status}} when status >= 500 -> post_with_retries(url, body, headers, rest)
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, _exception} -> post_with_retries(url, body, headers, rest)
    end
  end
end
