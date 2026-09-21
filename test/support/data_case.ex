defmodule You.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use You.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias You.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import You.DataCase
    end
  end

  setup tags do
    You.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  Two things happen here beyond the ordinary checkout.

  **The transaction takes the write lock immediately.** The sandbox begins
  each test's transaction with a hardcoded `mode: :transaction`
  (`Ecto.Adapters.SQL.Sandbox.post_checkout/3`), which `Exqlite.Connection`
  maps to a deferred `BEGIN TRANSACTION` — the repo's
  `default_transaction_mode: :immediate` is never consulted for it. A
  deferred transaction that reads before it writes is a reader holding a
  snapshot, and SQLite fails such a writer with `SQLITE_BUSY` *immediately*,
  without ever calling the busy handler, because waiting could deadlock two
  readers. No `busy_timeout` can help there; that is the CI flake in #161.
  Issuing a write as the transaction's very first statement takes the write
  lock at a point where the busy handler still applies, so a blocked test
  waits for the lock instead of failing. The statement matches no rows, so it
  writes nothing; only the lock it acquires matters. It is rolled back with
  everything else at the end of the test.

  **In-flight webhook deliveries are stopped.** `You.Accounts.register_user/1`
  emits telemetry that fans out into `You.Webhooks.Dispatcher`, so any test
  creating a user starts delivery tasks. Those tasks outlive the test: they
  sleep between attempts and post to a server that no longer exists, logging
  against whichever test is running by then (#159). Terminating them and
  clearing the endpoint cache — whose rows the sandbox has just rolled back —
  confines a delivery to the test that caused it.

  Two honest limits on that. ExUnit stops `start_supervised!` children before
  it runs `on_exit`, so a delivery sleeping between attempts can still post to
  an already-dead server in that window; the test backoff is 10ms, so the
  window is small, but it is not zero. And terminating deliveries is a global
  action: an async test's teardown will also kill a concurrently running test's
  deliveries. No async test asserts on deliveries today — a test that needs to
  would have to own the dispatcher rather than share it.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(You.Repo, shared: not tags[:async])

    You.Repo.query!("DELETE FROM schema_migrations WHERE 0")

    on_exit(fn ->
      stop_webhook_deliveries()
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)
  end

  defp stop_webhook_deliveries do
    You.Webhooks.Dispatcher.clear_cache()
    terminate_deliveries()
  end

  # Repeats until no children are left: the outer fan-out task starts one child
  # per endpoint, so a child can appear between the listing and the termination.
  # A terminated fan-out task cannot start further children, so this settles.
  defp terminate_deliveries do
    case Task.Supervisor.children(You.Webhooks.TaskSupervisor) do
      [] ->
        :ok

      pids ->
        Enum.each(pids, &Task.Supervisor.terminate_child(You.Webhooks.TaskSupervisor, &1))
        terminate_deliveries()
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
