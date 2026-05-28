defmodule You.IAM.ClientTest do
  use You.DataCase, async: false

  alias You.AccountsFixtures

  describe "verify_token/1" do
    test "returns user info for valid JWT" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, jwt} = You.JWT.sign(%{sub: user.id, email: user.email, app: "sockeet", role: "admin"})

      assert {:ok, info} = You.IAM.Client.verify_token(jwt)
      assert info.user_id == user.id
      assert info.email == user.email
      assert info.role == "admin"
    end

    test "returns error for invalid JWT" do
      assert {:error, :invalid_signature} = You.IAM.Client.verify_token("bad.token.here")
    end
  end

  describe "get_user/1" do
    test "returns user info for existing user" do
      user = AccountsFixtures.user_fixture()
      assert {:ok, info} = You.IAM.Client.get_user(user.id)
      assert info.id == user.id
      assert info.email == user.email
    end

    test "returns error for non-existent user" do
      assert {:error, :not_found} = You.IAM.Client.get_user(999_999)
    end
  end

  describe "revoke_token/1" do
    test "revokes a JWT" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, jwt} = You.JWT.sign(%{sub: user.id, email: user.email, app: "sockeet", role: "admin"})

      assert :ok = You.IAM.Client.revoke_token(jwt)
      assert {:error, :revoked} = You.IAM.Client.verify_token(jwt)
    end
  end
end
