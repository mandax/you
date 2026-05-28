defmodule You.Accounts.SessionExpiryTest do
  use You.DataCase, async: false

  alias You.Accounts
  alias You.AccountsFixtures
  alias You.Settings

  describe "session token respects settings" do
    test "get_user_by_session_token returns user with default expiry" do
      user = AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert {found, _inserted_at} = Accounts.get_user_by_session_token(token)
      assert found.id == user.id
    end

    test "get_user_by_session_token returns nil when session_expiry_hours is 0" do
      :ok = Settings.set(:session_expiry_hours, 0)
      user = AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.get_user_by_session_token(token) == nil
    end
  end
end
