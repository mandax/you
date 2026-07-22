defmodule You.Accounts.FederatedIdentityTest do
  use You.DataCase, async: false

  alias You.Accounts
  alias You.AccountsFixtures

  describe "find_or_create_user_by_federated_identity/3" do
    test "creates a new confirmed user when email is unknown" do
      assert {:ok, user} =
               Accounts.find_or_create_user_by_federated_identity(
                 "google",
                 "google-sub-123",
                 "newuser@example.com"
               )

      assert user.email == "newuser@example.com"
      assert user.confirmed_at
      refute user.hashed_password
    end

    test "creates a FederatedIdentity record for new user" do
      {:ok, user} =
        Accounts.find_or_create_user_by_federated_identity(
          "google",
          "google-sub-456",
          "feduser@example.com"
        )

      fed = Accounts.get_federated_identity("google", "google-sub-456")
      assert fed
      assert fed.user_id == user.id
      assert fed.provider == "google"
      assert fed.subject == "google-sub-456"
      assert fed.email == "feduser@example.com"
    end

    test "links to existing user by email" do
      existing = AccountsFixtures.user_fixture()

      assert {:ok, user} =
               Accounts.find_or_create_user_by_federated_identity(
                 "github",
                 "gh-sub-789",
                 existing.email
               )

      assert user.id == existing.id

      fed = Accounts.get_federated_identity("github", "gh-sub-789")
      assert fed
      assert fed.user_id == existing.id
    end

    test "idempotent re-login returns the same user" do
      assert {:ok, first} =
               Accounts.find_or_create_user_by_federated_identity(
                 "google",
                 "google-repeated",
                 "repeat@example.com"
               )

      assert {:ok, second} =
               Accounts.find_or_create_user_by_federated_identity(
                 "google",
                 "google-repeated",
                 "repeat@example.com"
               )

      assert first.id == second.id

      # Should still only have one FederatedIdentity record
      identities = Accounts.list_federated_identities_for_user(first)
      assert length(identities) == 1
    end

    test "different providers for the same email link to the same user" do
      email = AccountsFixtures.unique_user_email()

      # First login via Google
      {:ok, user1} =
        Accounts.find_or_create_user_by_federated_identity("google", "g-sub", email)

      # Second login via GitHub with same email
      {:ok, user2} =
        Accounts.find_or_create_user_by_federated_identity("github", "gh-sub", email)

      assert user1.id == user2.id

      identities = Accounts.list_federated_identities_for_user(user1)
      assert length(identities) == 2
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
end
