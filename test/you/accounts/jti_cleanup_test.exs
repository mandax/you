defmodule You.Accounts.JtiCleanupTest do
  use You.DataCase, async: false

  alias You.Accounts
  alias You.Repo
  import Ecto.Query

  describe "cleanup_revoked_jtis/0" do
    setup do
      user = You.AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "deletes expired revocation entries", %{user: user} do
      Repo.insert!(%You.Accounts.UserToken{
        token: :crypto.strong_rand_bytes(32),
        context: "jti_revoked",
        user_id: user.id,
        authenticated_at: ~U[2020-01-01 00:00:00Z],
        inserted_at: ~U[2020-01-01 00:00:00Z]
      })

      Accounts.cleanup_revoked_jtis()

      assert Repo.all(from t in You.Accounts.UserToken, where: t.context == "jti_revoked") == []
    end

    test "keeps non-expired revocation entries", %{user: user} do
      Repo.insert!(%You.Accounts.UserToken{
        token: :crypto.strong_rand_bytes(32),
        context: "jti_revoked",
        user_id: user.id,
        authenticated_at: DateTime.utc_now() |> DateTime.truncate(:second),
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      Accounts.cleanup_revoked_jtis()

      assert Repo.all(from t in You.Accounts.UserToken, where: t.context == "jti_revoked")
             |> length() == 1
    end
  end
end
