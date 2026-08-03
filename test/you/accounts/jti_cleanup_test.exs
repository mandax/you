defmodule You.Accounts.JtiCleanupTest do
  use You.DataCase, async: false

  alias You.Accounts
  alias You.Accounts.RevokedJti
  alias You.Repo

  describe "cleanup_revoked_jtis/0" do
    test "deletes expired revocation entries" do
      Repo.insert!(%RevokedJti{
        jti_hash: :crypto.strong_rand_bytes(32),
        subject: "1",
        inserted_at: ~U[2020-01-01 00:00:00Z]
      })

      Accounts.cleanup_revoked_jtis()

      assert Repo.all(RevokedJti) == []
    end

    test "keeps non-expired revocation entries" do
      Repo.insert!(%RevokedJti{
        jti_hash: :crypto.strong_rand_bytes(32),
        subject: "1",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      Accounts.cleanup_revoked_jtis()

      assert Repo.aggregate(RevokedJti, :count) == 1
    end
  end
end
