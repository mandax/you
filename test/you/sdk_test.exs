defmodule You.SDKTest do
  use You.DataCase, async: false

  import ExUnit.CaptureLog

  alias You.AccountsFixtures

  describe "exchange_code/1" do
    test "returns JWT for valid auth code" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, code} = You.Accounts.generate_auth_code(user)

      assert {:ok, info} = You.SDK.exchange_code(code)
      assert info.user_id == user.id
      assert info.email == user.email
      assert is_binary(info.jwt)
    end

    test "returns error for invalid code" do
      assert {:error, :not_found} = You.SDK.exchange_code("invalid")
    end
  end

  describe "error handling" do
    test "returns :unreachable when the node is down" do
      assert {:error, :unreachable} = You.SDK.get_user(1, node: :"you@definitely-not-here")
    end

    test "returns :unreachable when the call times out" do
      :ok = :sys.suspend(You.IAM.Server)

      assert {:error, :unreachable} = You.SDK.get_user(1, timeout: 50)

      # Kill the suspended server so its queued message is dropped with it —
      # resuming would run the query after this test's sandbox owner is gone
      # and crash the server ("owner exited") under later tests.
      Process.exit(Process.whereis(You.IAM.Server), :boom)
      await_iam_server()
    end

    test "returns :server_error and logs when the server dies mid-call" do
      :ok = :sys.suspend(You.IAM.Server)
      pid = Process.whereis(You.IAM.Server)

      log =
        capture_log(fn ->
          task = Task.async(fn -> You.SDK.get_user(1) end)
          await_queued_call(pid)

          # A plain exit reason maps to :server_error (:kill would propagate
          # as an untrappable exit and kill the caller too).
          Process.exit(pid, :boom)
          assert {:error, :server_error} = Task.await(task)
        end)

      assert log =~ "IAM call"

      # The supervisor restarts the crashed server asynchronously. Wait for
      # the fresh process so later tests never race a mid-restart server.
      await_iam_server()
    end
  end

  defp await_queued_call(pid, retries \\ 100)
  defp await_queued_call(_pid, 0), do: flunk("SDK call never reached the suspended server")

  defp await_queued_call(pid, retries) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} when n > 0 ->
        :ok

      _ ->
        Process.sleep(10)
        await_queued_call(pid, retries - 1)
    end
  end

  defp await_iam_server(retries \\ 100)
  defp await_iam_server(0), do: flunk("You.IAM.Server did not restart in time")

  defp await_iam_server(retries) do
    with pid when is_pid(pid) <- Process.whereis(You.IAM.Server),
         true <- Process.alive?(pid),
         {:ok, _state} <- safe_get_state(pid) do
      :ok
    else
      _ ->
        Process.sleep(10)
        await_iam_server(retries - 1)
    end
  end

  defp safe_get_state(pid) do
    {:ok, :sys.get_state(pid, 100)}
  catch
    :exit, _ -> :error
  end
end
