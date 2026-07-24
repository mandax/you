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
      on_exit(fn -> :sys.resume(You.IAM.Server) end)

      assert {:error, :unreachable} = You.SDK.get_user(1, timeout: 50)
    end

    test "returns :server_error and logs when the server crashes" do
      log =
        capture_log(fn ->
          # A non-integer id raises Ecto.Query.CastError inside the server
          assert {:error, :server_error} = You.SDK.get_user("not-an-id")
        end)

      assert log =~ "IAM call"
    end
  end
end
