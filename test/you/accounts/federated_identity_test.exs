defmodule You.Accounts.FederatedIdentityTest do
  use You.DataCase, async: false

  alias You.Accounts
  alias You.AccountsFixtures

  describe "find_or_create_user_by_federated_identity/4" do
    test "creates a new confirmed user when email is unknown and verified" do
      assert {:ok, user} =
               Accounts.find_or_create_user_by_federated_identity(
                 "google",
                 "google-sub-123",
                 "newuser@example.com",
                 true
               )

      assert user.email == "newuser@example.com"
      assert user.confirmed_at
      refute user.hashed_password
    end

    test "creates an UNCONFIRMED user when the new email is not verified" do
      assert {:ok, user} =
               Accounts.find_or_create_user_by_federated_identity(
                 "google",
                 "google-sub-unv",
                 "unverified@example.com",
                 false
               )

      assert user.email == "unverified@example.com"
      refute user.confirmed_at
    end

    test "creates a FederatedIdentity record for new user" do
      {:ok, user} =
        Accounts.find_or_create_user_by_federated_identity(
          "google",
          "google-sub-456",
          "feduser@example.com",
          true
        )

      fed = Accounts.get_federated_identity("google", "google-sub-456")
      assert fed
      assert fed.user_id == user.id
      assert fed.provider == "google"
      assert fed.subject == "google-sub-456"
      assert fed.email == "feduser@example.com"
    end

    test "links to an existing user by email when the IdP email is verified" do
      existing = AccountsFixtures.user_fixture()

      assert {:ok, user} =
               Accounts.find_or_create_user_by_federated_identity(
                 "github",
                 "gh-sub-789",
                 existing.email,
                 true
               )

      assert user.id == existing.id
      assert Accounts.get_federated_identity("github", "gh-sub-789").user_id == existing.id
    end

    test "REFUSES to link to an existing account when the IdP email is not verified" do
      existing = AccountsFixtures.user_fixture()

      assert {:error, :email_not_verified} =
               Accounts.find_or_create_user_by_federated_identity(
                 "github",
                 "attacker-sub",
                 existing.email,
                 false
               )

      # no identity was created, the victim account is untouched
      refute Accounts.get_federated_identity("github", "attacker-sub")
      assert Accounts.list_federated_identities_for_user(existing) == []
    end

    test "defaults to unverified (refuses linking) when email_verified is omitted" do
      existing = AccountsFixtures.user_fixture()

      assert {:error, :email_not_verified} =
               Accounts.find_or_create_user_by_federated_identity(
                 "github",
                 "omitted-sub",
                 existing.email
               )
    end

    test "idempotent re-login returns the same user" do
      assert {:ok, first} =
               Accounts.find_or_create_user_by_federated_identity(
                 "google",
                 "google-repeated",
                 "repeat@example.com",
                 true
               )

      assert {:ok, second} =
               Accounts.find_or_create_user_by_federated_identity(
                 "google",
                 "google-repeated",
                 "repeat@example.com",
                 true
               )

      assert first.id == second.id
      assert length(Accounts.list_federated_identities_for_user(first)) == 1
    end

    test "different verified providers for the same email link to the same user" do
      email = AccountsFixtures.unique_user_email()

      {:ok, user1} =
        Accounts.find_or_create_user_by_federated_identity("google", "g-sub", email, true)

      {:ok, user2} =
        Accounts.find_or_create_user_by_federated_identity("github", "gh-sub", email, true)

      assert user1.id == user2.id
      assert length(Accounts.list_federated_identities_for_user(user1)) == 2
    end
  end

  describe "get_federated_identity/2" do
    test "returns nil for unknown provider + subject" do
      assert Accounts.get_federated_identity("unknown", "no-such-subject") == nil
    end
  end

  describe "list_federated_identities_for_user/1" do
    test "returns empty list for user with no federated identities" do
      user = AccountsFixtures.user_fixture()
      assert Accounts.list_federated_identities_for_user(user) == []
    end
  end

  describe "delete_federated_identity/2" do
    test "deletes the identity and returns 1" do
      Accounts.find_or_create_user_by_federated_identity(
        "google",
        "to-delete",
        "del@example.com"
      )

      assert Accounts.delete_federated_identity("google", "to-delete") == 1
      assert Accounts.get_federated_identity("google", "to-delete") == nil
    end

    test "returns 0 when no match" do
      assert Accounts.delete_federated_identity("nope", "nope") == 0
    end
  end

  describe "delete_user_federated_identity/2" do
    test "unlinks only when owned by the user" do
      {:ok, owner} =
        Accounts.find_or_create_user_by_federated_identity("google", "own", "o@e.com")

      other = You.AccountsFixtures.user_fixture()
      [identity] = Accounts.list_federated_identities_for_user(owner)

      # A different user cannot unlink someone else's identity.
      assert {0, _} = Accounts.delete_user_federated_identity(other, identity.id)
      assert Accounts.get_federated_identity("google", "own")

      # The owner can.
      assert {1, _} = Accounts.delete_user_federated_identity(owner, identity.id)
      assert Accounts.get_federated_identity("google", "own") == nil
    end
  end
end
