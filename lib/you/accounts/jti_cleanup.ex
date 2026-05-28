defmodule You.Accounts.JtiCleanup do
  @moduledoc """
  Periodically cleans up expired JTI revocation entries.

  Runs every hour. Configured in the supervision tree.
  """

  use GenServer

  @cleanup_interval :timer.hours(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    schedule_cleanup()
    {:ok, opts}
  end

  @impl true
  def handle_info(:cleanup, state) do
    You.Accounts.cleanup_revoked_jtis()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
