defmodule You.JWTRevocationTest do
  @moduledoc """
  Revocation is idempotent and works for every kind of subject.

  RFC 7009 requires `/oauth/revoke` to answer 200 even for a token that is
  already revoked, and clients retry it after a network failure. Service
  tokens carry an app slug as their subject rather than a user id.
  """
  use You.DataCase, async: false

  alias You.Accounts.RevokedJti
  alias You.JWT

  setup do
    user = You.AccountsFixtures.user_fixture()
    {:ok, jwt} = JWT.sign(%{sub: user.id, email: user.email, app: "myapp"}, 3600)
    %{user: user, jwt: jwt}
  end

  test "revoking twice succeeds and stores one row", %{jwt: jwt} do
    assert :ok = JWT.revoke(jwt)
    assert :ok = JWT.revoke(jwt)

    assert Repo.aggregate(RevokedJti, :count) == 1
    assert {:error, :revoked} = JWT.verify(jwt)
  end

  test "a service token whose subject is an app slug can be revoked" do
    {:ok, service_jwt} = JWT.sign(%{sub: "some-app", app: "you", type: "service"}, 3600)

    assert :ok = JWT.revoke(service_jwt)
    assert {:error, :revoked} = JWT.verify(service_jwt)
    assert %{subject: "some-app"} = Repo.one(RevokedJti)
  end

  test "revoking one token leaves another valid", %{jwt: jwt, user: user} do
    {:ok, other} = JWT.sign(%{sub: user.id, email: user.email, app: "myapp"}, 3600)

    assert :ok = JWT.revoke(jwt)

    assert {:error, :revoked} = JWT.verify(jwt)
    assert {:ok, _claims} = JWT.verify(other)
  end

  test "cleanup drops entries past the retention window", %{jwt: jwt} do
    assert :ok = JWT.revoke(jwt)

    stale = DateTime.utc_now() |> DateTime.add(-72 * 3600, :second) |> DateTime.truncate(:second)
    Repo.update_all(RevokedJti, set: [inserted_at: stale])

    You.Accounts.cleanup_revoked_jtis()

    assert Repo.aggregate(RevokedJti, :count) == 0
  end
end
