defmodule You.Cache do
  @moduledoc """
  Cluster-wide invalidation for the caches You keeps in `:persistent_term`.

  `You.Settings` and `You.Mode` cache values that are read on hot paths and
  written rarely. Both invalidate in-process on the node that made the write,
  which is correct while there is one node and wrong the moment there are two:
  an admin renaming the app or rotating `api_token` on one node would leave
  every other node serving the old value until it restarted — and for
  `api_token` that is an authentication decision made against a stale
  credential.

  Writers call `You.Settings.invalidate/1` or `You.Mode.invalidate_app_cache/0`,
  which drop the local copy synchronously — the request that made the edit must
  read its own write — and then broadcast here. This process applies the
  broadcast on every *other* node; the originating node skips it, having
  already done the work.

  Invalidation drops a cached value rather than shipping the new one. The
  database is the single source of truth, and a payload carrying a value could
  arrive out of order with the write that produced it.
  """

  use GenServer

  require Logger

  @topic "you:cache"

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Tells every other node to drop its cached copy of `target`.

  Never raises: an invalidation that cannot be delivered must not take down
  the write that triggered it. The local node has already dropped its own
  copy by the time this is called.
  """
  def broadcast(target) do
    Phoenix.PubSub.broadcast(You.PubSub, @topic, {:invalidate, target, node()})
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_opts) do
    :ok = Phoenix.PubSub.subscribe(You.PubSub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:invalidate, _target, origin}, state) when origin == node() do
    {:noreply, state}
  end

  def handle_info({:invalidate, target, _origin}, state) do
    drop(target)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A failed reload leaves the stale value in place rather than crashing the
  # notifier and losing every later invalidation with it.
  defp drop(target) do
    do_drop(target)
  rescue
    error ->
      Logger.warning("[You.Cache] could not invalidate #{inspect(target)}: #{inspect(error)}")
  end

  defp do_drop({:setting, key}), do: You.Settings.refresh(key)
  defp do_drop(:single_app), do: You.Mode.drop_app_cache()
end
