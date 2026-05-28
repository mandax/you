defmodule You.SDKTest do
  use You.DataCase, async: false

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
end
