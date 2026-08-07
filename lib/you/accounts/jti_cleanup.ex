defmodule You.Accounts.JtiCleanup do
  @moduledoc """
  Periodic cleanup of rows nothing is coming back for: expired JTI revocation
  entries, guest accounts that were never upgraded, and federated login flows
  nobody returned from the IdP to complete.

  Runs every hour. Configured in the supervision tree.
  """

  use GenServer

  @cleanup_interval :timer.hours(1)

  # A guest nobody upgraded within a month is a row with no person behind it.
  # Long enough that a returning visitor with a stored token still finds their
  # cart; short enough that abandoned guests do not accumulate forever.
  @guest_retention_days 30

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
    You.Guests.delete_stale(@guest_retention_days)
    You.IdentityProviders.cleanup_expired_login_flows()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
