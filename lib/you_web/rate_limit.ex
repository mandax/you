defmodule YouWeb.RateLimit do
  @moduledoc """
  ETS-backed fixed-window counters behind `YouWeb.Plugs.RateLimit`.

  The GenServer only owns the table and periodically sweeps expired
  windows; `check/4` hits ETS directly so requests never serialize
  through a single process. Entries are `{bucket, window_start, count,
  expires_at}`.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.minutes(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a hit for `bucket` in the current `window_ms` window.

  Returns `{:allow, count}` while `count <= limit`, otherwise
  `{:deny, retry_after_ms}` with the milliseconds left in the window.

  Pass `now: milliseconds` to inject the clock in tests.
  """
  def check(bucket, limit, window_ms, opts \\ []) do
    now = Keyword.get(opts, :now, System.monotonic_time(:millisecond))
    # Integer.mod floors even for the negative values monotonic_time can return
    window_start = now - Integer.mod(now, window_ms)
    expires_at = window_start + window_ms

    count = hit(bucket, window_start, expires_at)

    if count <= limit do
      {:allow, count}
    else
      {:deny, expires_at - now}
    end
  end

  @doc "Configured `{limit, window_ms}` for `key`, or `nil` when unlimited."
  def limit_for(key) do
    :you |> Application.get_env(__MODULE__, %{}) |> Map.get(key)
  end

  defp hit(bucket, window_start, expires_at) do
    case :ets.lookup(@table, bucket) do
      [{^bucket, ^window_start, _count, _expires_at}] ->
        # Default tuple makes the counter update atomic even if the sweep
        # evicts the entry between lookup and update.
        :ets.update_counter(@table, bucket, {3, 1}, {bucket, window_start, 0, expires_at})

      _stale_or_missing ->
        :ets.insert(@table, {bucket, window_start, 1, expires_at})
        1
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
