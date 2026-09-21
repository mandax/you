defmodule You.SandboxLockTest do
  @moduledoc """
  Pins the mechanism behind #161 so a regression is a failing test rather than
  a flake somebody has to reproduce 15 times.

  The sandbox begins each test's transaction deferred (see
  `You.DataCase.setup_sandbox/1` for why `default_transaction_mode: :immediate`
  does not reach it). A deferred transaction holds no write lock until it
  writes, and by then it is a reader upgrading — the case SQLite fails
  instantly with `SQLITE_BUSY`, busy handler never consulted. `setup_sandbox/1`
  writes as its first statement so the lock is taken up front instead.

  Asserting on the lock directly, from a separate connection, is what makes
  this a test of the mechanism rather than of how often the race happens to be
  lost. It fails if that first write is removed.
  """
  use You.DataCase, async: false

  test "the sandbox transaction already holds the write lock" do
    {:ok, other} = Exqlite.Sqlite3.open(You.Repo.config()[:database])
    on_exit(fn -> Exqlite.Sqlite3.close(other) end)

    # Fail rather than wait: this asserts the lock is held *now*.
    :ok = Exqlite.Sqlite3.execute(other, "PRAGMA busy_timeout = 0")

    # Match the lock reason specifically: any `{:error, _}` would also be
    # satisfied by an unrelated failure (a missing file, a bad pragma).
    assert {:error, reason} = Exqlite.Sqlite3.execute(other, "BEGIN IMMEDIATE")
    assert reason =~ "busy" or reason =~ "locked", "unexpected error: #{inspect(reason)}"
  end
end
