defmodule You.Webhooks.Dispatcher do
  @moduledoc """
  Delivers webhook payloads to subscribed endpoints.

  Attaches to the same `[:you, :audit, ...]` telemetry events as the audit
  streamer. Endpoints are cached in the GenServer state (refreshed via
  `reload/0` whenever `You.Webhooks` mutates them), so deliveries never
  touch the database on the hot path. Each endpoint gets its own delivery
  task with up to 3 attempts (by default immediate, +2s, +10s); a slow or
  failing endpoint never delays the others. Deliveries are not persisted; a
  restart drops in-flight retries.

  The attempt schedule is `config :you, :webhook_retry_backoff` — a list of
  millisecond waits, one per attempt, read at delivery time rather than at
  compile time. Dev and prod set nothing and get the default below; the test
  environment shortens it so the suite verifies the retry *policy* without
  buying ~12s of real sleeping (#159).

  Deliveries run as children of `You.Webhooks.TaskSupervisor`, which is what
  lets the test suite terminate an in-flight delivery instead of letting it
  wake up mid-backoff and post against whichever test happens to be running
  by then.
  """
  use GenServer
  require Logger

  alias You.Webhooks

  @req_timeout 5_000
  @default_retry_backoff [0, 2_000, 10_000]
  @task_supervisor You.Webhooks.TaskSupervisor

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

  @impl true
  def handle_call(:clear_cache, _from, state) do
    {:reply, :ok, %{state | endpoints: []}}
  end

  @doc false
  def handle_event(event_name, _measurements, metadata, _config) do
    event_type = Webhooks.event_type(event_name)

    # Telemetry detaches a handler that raises or exits, so a momentarily
    # absent Task.Supervisor would silently turn webhook delivery off for the
    # rest of the VM's life. A dropped delivery is the lesser failure: these
    # are already fire-and-forget and a restart drops in-flight retries anyway.
    start_delivery(fn ->
      event_type
      |> subscribed()
      |> Enum.each(fn endpoint ->
        start_delivery(fn -> deliver(endpoint, event_type, metadata) end)
      end)
    end)

    :ok
  end

  defp start_delivery(fun) do
    Task.Supervisor.start_child(@task_supervisor, fun)
  catch
    :exit, reason ->
      Logger.warning("webhook delivery could not be started: #{inspect(reason)}")
      :ok
  end

  @doc """
  Clears the cached endpoints.

  The cache is deliberately not backed by the database on the hot path, so
  nothing tells it when rows go away underneath it. The test sandbox rolls
  every endpoint row back at the end of a test, which is exactly that case:
  without this the dispatcher would keep posting to the previous test's
  now-dead server for the rest of the run (#159).

  Only the test suite calls this; production invalidates the cache through
  `reload/0`, which refills it from the database instead of emptying it.
  """
  def clear_cache do
    if pid = Process.whereis(__MODULE__) do
      GenServer.call(pid, :clear_cache)
    else
      :ok
    end
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

    backoff = retry_backoff()

    case post_with_retries(endpoint.url, body, headers, backoff) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "webhook delivery to #{endpoint.url} failed after #{length(backoff)} attempts: #{inspect(reason)}"
        )
    end
  end

  defp retry_backoff do
    Application.get_env(:you, :webhook_retry_backoff, @default_retry_backoff)
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
