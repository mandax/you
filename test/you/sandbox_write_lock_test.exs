defmodule You.SandboxWriteLockTest do
  @moduledoc """
  Guards the fix for #161 in `You.DataCase.setup_sandbox/1`.

  `You.SandboxLockTest` pins the SQLite behaviour that makes the fix necessary,
  but it uses owners of its own and passes whether or not `setup_sandbox/1`
  writes first. This test fails if that write is removed.

  It must stay `async: true`. A shared-mode checkout, which is what
  `async: false` gives, holds the write lock for its own reasons, and the
  assertion below would then pass with no fix in place.

  `Process.sleep/1` appears here against the rule in AGENTS.md. The assertion
  is that nothing comes back while the lock is held, so there is no message to
  wait for.
  """
  use You.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  test "setup_sandbox/1 leaves this test holding the write lock" do
    task =
      Task.async(fn ->
        owner = Sandbox.start_owner!(You.Repo, shared: false)

        try do
          SQL.query!(You.Repo, "DELETE FROM schema_migrations WHERE 0", [])
          :acquired
        after
          Sandbox.stop_owner(owner)
        end
      end)

    assert nil == Task.yield(task, 250),
           "a second owner took the write lock, so setup_sandbox/1 no longer takes it first"

    Task.shutdown(task, :brutal_kill)
  end
end
