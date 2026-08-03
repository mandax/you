defmodule You.Accounts.UserSessionsTest do
  use You.DataCase, async: false

  import You.AccountsFixtures
  alias You.Accounts

  setup do
    %{user: user_fixture()}
  end

  test "lists a user's sessions newest first", %{user: user} do
    _t1 = Accounts.generate_user_session_token(user)
    _t2 = Accounts.generate_user_session_token(user)
    assert length(Accounts.list_user_sessions(user)) == 2
  end

  test "revokes one session by id, scoped to the user", %{user: user} do
    Accounts.generate_user_session_token(user)
    [session | _] = Accounts.list_user_sessions(user)

    # another user can't revoke it
    other = user_fixture()
    assert Accounts.delete_user_session(other, session.id) == 0
    assert length(Accounts.list_user_sessions(user)) == 1

    # the owner can
    assert Accounts.delete_user_session(user, session.id) == 1
    assert Accounts.list_user_sessions(user) == []
  end

  test "revokes every session except the current one", %{user: user} do
    keep = Accounts.generate_user_session_token(user)
    _drop1 = Accounts.generate_user_session_token(user)
    _drop2 = Accounts.generate_user_session_token(user)

    assert Accounts.delete_other_user_sessions(user, keep) == 2
    remaining = Accounts.list_user_sessions(user)
    assert length(remaining) == 1
    assert hd(remaining).token == keep
  end
end
