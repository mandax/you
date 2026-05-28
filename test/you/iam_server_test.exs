defmodule You.IAMServerTest do
  use You.DataCase, async: false

  alias You.AccountsFixtures

  describe "verify_token" do
    test "returns user info for valid JWT" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, jwt} = You.JWT.sign(%{sub: user.id, email: user.email, app: "sockeet", role: "admin"})

      assert {:ok, info} = GenServer.call(You.IAM.Server, {:verify_token, jwt})
      assert info.user_id == user.id
      assert info.email == user.email
      assert info.role == "admin"
    end

    test "returns error for expired JWT" do
      user = AccountsFixtures.user_fixture()

      {:ok, jwt} =
        You.JWT.sign(%{sub: user.id, email: user.email, app: "sockeet", role: "admin"}, -3600)

      assert {:error, :expired} = GenServer.call(You.IAM.Server, {:verify_token, jwt})
    end

    test "returns error for revoked JWT" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, jwt} = You.JWT.sign(%{sub: user.id, email: user.email, app: "sockeet", role: "admin"})

      You.JWT.revoke(jwt)

      assert {:error, :revoked} = GenServer.call(You.IAM.Server, {:verify_token, jwt})
    end

    test "returns error for invalid JWT" do
      assert {:error, :invalid_signature} =
               GenServer.call(You.IAM.Server, {:verify_token, "garbage.token.here"})
    end
  end

  describe "get_user" do
    test "returns user info for existing user" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, info} = GenServer.call(You.IAM.Server, {:get_user, user.id})
      assert info.id == user.id
      assert info.email == user.email
    end

    test "returns error for non-existent user" do
      assert {:error, :not_found} = GenServer.call(You.IAM.Server, {:get_user, 999_999})
    end
  end

  describe "revoke_token" do
    test "revokes a JWT so subsequent verify returns revoked" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, jwt} = You.JWT.sign(%{sub: user.id, email: user.email, app: "sockeet", role: "admin"})

      assert :ok = GenServer.call(You.IAM.Server, {:revoke_token, jwt})
      assert {:error, :revoked} = GenServer.call(You.IAM.Server, {:verify_token, jwt})
    end
  end
end
