defmodule You.SandboxLockTest do
  @moduledoc """
  Pins the mechanism behind #161, so a regression is a failing test and not a
  flake that somebody must reproduce 15 times.

  The sandbox begins each test transaction deferred. It calls the adapter with
  a hardcoded `mode: :transaction` (`Ecto.Adapters.SQL.Sandbox.post_checkout/3`),
  and `Exqlite.Connection.handle_begin/2` maps that to a plain
  `BEGIN TRANSACTION`. The repo option `default_transaction_mode: :immediate`
  is never consulted for it.

  A deferred transaction that reads before it writes is a reader that must
  upgrade to a writer. SQLite refuses that upgrade with `SQLITE_BUSY` at once,
  and it does not call the busy handler, because a wait there can deadlock two
  readers. No `busy_timeout` value prevents this.

  The two tests below are a control and its fix. The control shows the raw
  refusal. The second shows that a write as the first statement — what
  `You.DataCase.setup_sandbox/1` now does — makes the same sequence wait for
  the lock and then succeed.

  These tests pin SQLite and sandbox behaviour with two owners of their own.
  They do not exercise `setup_sandbox/1`, and they pass whether or not it
  writes first. `You.SandboxWriteLockTest` is the test that guards the fix.

  `Process.sleep/1` appears here against the rule in AGENTS.md. The assertions
  are about how long an operation takes to come back, so there is no message to
  wait for: the control asserts a refusal arrives at once, and the fix asserts
  that nothing arrives while the lock is held.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  # Matches no rows, so it writes nothing. Only the write lock that it takes
  # matters. The sandbox rolls it back with everything else.
  @take_write_lock "DELETE FROM schema_migrations WHERE 0"

  @select "SELECT count(*) FROM users"

  setup do
    # Owner A holds the write lock for the whole test. Owner B, in a task,
    # contends for it.
    holder = Sandbox.start_owner!(You.Repo, shared: false)

    # `start_owner!/2` starts an unlinked agent, so a failed assertion would
    # otherwise leave this owner holding the write lock for the rest of the
    # run, and every later test would fail with "Database busy". A test that
    # releases the lock itself makes this a no-op.
    on_exit(fn ->
      if Process.alive?(holder), do: Sandbox.stop_owner(holder)
    end)

    SQL.query!(You.Repo, @take_write_lock, [])

    %{holder: holder}
  end

  test "a reader that upgrades to a writer fails at once: the #161 flake" do
    task = contend(fn -> SQL.query!(You.Repo, @select, []) end)

    # Long enough that an immediate SQLITE_BUSY has already come back.
    Process.sleep(250)
    assert {:ok, {{:error, message}, elapsed}} = Task.yield(task, 100)

    assert message =~ "Database busy"

    assert elapsed < 100,
           "expected an immediate refusal, but the busy handler waited #{elapsed}ms"
  end

  test "taking the write lock first makes the same sequence wait, not fail", %{holder: holder} do
    task = contend(fn -> :ok end)

    # B is blocked on A's write lock rather than refused. The control above
    # already returned by this point.
    Process.sleep(250)
    assert nil == Task.yield(task, 0), "expected the second owner to wait for the lock"

    Sandbox.stop_owner(holder)

    # It succeeds once the lock is free. The wait above is the assertion about
    # blocking; a bound on the elapsed time here would only add a timing flake.
    assert is_integer(Task.await(task, 30_000))
  end

  # Owner B: `before_lock` runs before B takes the write lock. Passing a read
  # there is the broken order; passing a no-op is the order `setup_sandbox/1`
  # now uses.
  defp contend(before_lock) do
    Task.async(fn ->
      owner = Sandbox.start_owner!(You.Repo, shared: false)

      try do
        before_lock.()
        started = System.monotonic_time(:millisecond)

        result =
          try do
            SQL.query!(You.Repo, @take_write_lock, [])
            :ok
          rescue
            error -> {:error, Exception.message(error)}
          end

        elapsed = System.monotonic_time(:millisecond) - started

        case result do
          :ok -> elapsed
          error -> {error, elapsed}
        end
      after
        Sandbox.stop_owner(owner)
      end
    end)
  end
end
