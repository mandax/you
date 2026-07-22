defmodule You.Accounts.PasskeyTest do
  use You.DataCase, async: false

  alias You.Accounts
  alias You.Accounts.Passkey

  import You.AccountsFixtures

  describe "Passkey schema and context functions" do
    @valid_cose_key %{
      -3 => <<0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0>>,
      -2 => <<0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10>>,
      -1 => 1,
      1 => 2,
      3 => -7
    }

    test "register_passkey/2 creates a new passkey for a user" do
      user = user_fixture()
      credential_id = :crypto.strong_rand_bytes(16)

      assert {:ok, passkey} =
               Accounts.register_passkey(user, %{
                 credential_id: credential_id,
                 public_key: @valid_cose_key,
                 sign_count: 0,
                 label: "My YubiKey"
               })

      assert passkey.credential_id == credential_id
      assert passkey.public_key == Passkey.encode_cose_key(@valid_cose_key)
      assert passkey.sign_count == 0
      assert passkey.label == "My YubiKey"
      assert passkey.user_id == user.id
      assert passkey.aaguid == nil
    end

    test "register_passkey/2 accepts a pre-encoded public_key binary" do
      user = user_fixture()
      encoded = Passkey.encode_cose_key(@valid_cose_key)

      assert {:ok, passkey} =
               Accounts.register_passkey(user, %{
                 credential_id: :crypto.strong_rand_bytes(16),
                 public_key: encoded,
                 sign_count: 1
               })

      assert passkey.public_key == encoded
    end

    test "register_passkey/2 rejects duplicate credential_id" do
      user = user_fixture()
      credential_id = :crypto.strong_rand_bytes(16)

      assert {:ok, _} =
               Accounts.register_passkey(user, %{
                 credential_id: credential_id,
                 public_key: @valid_cose_key,
                 sign_count: 0
               })

      assert {:error, changeset} =
               Accounts.register_passkey(user, %{
                 credential_id: credential_id,
                 public_key: @valid_cose_key,
                 sign_count: 0
               })

      assert {:credential_id, {"has already been taken", _}} = hd(changeset.errors)
    end

    test "register_passkey/2 rejects missing required fields" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.register_passkey(user, %{credential_id: :crypto.strong_rand_bytes(16)})

      assert errors_on(changeset)[:public_key] == ["can't be blank"]
    end

    test "list_user_passkeys/1 returns the user's passkeys" do
      user = user_fixture()

      {:ok, pk1} =
        Accounts.register_passkey(user, %{
          credential_id: :crypto.strong_rand_bytes(16),
          public_key: @valid_cose_key,
          sign_count: 0,
          label: "First"
        })

      {:ok, pk2} =
        Accounts.register_passkey(user, %{
          credential_id: :crypto.strong_rand_bytes(16),
          public_key: @valid_cose_key,
          sign_count: 1,
          label: "Second"
        })

      passkeys = Accounts.list_user_passkeys(user)
      assert length(passkeys) == 2

      # Both passkeys are present
      ids = Enum.map(passkeys, & &1.id)
      assert pk1.id in ids
      assert pk2.id in ids
    end

    test "list_user_passkeys/1 returns empty list for user with no passkeys" do
      user = user_fixture()
      assert Accounts.list_user_passkeys(user) == []
    end

    test "list_user_passkeys/1 does not return other users' passkeys" do
      user1 = user_fixture()
      user2 = user_fixture()

      {:ok, _} =
        Accounts.register_passkey(user1, %{
          credential_id: :crypto.strong_rand_bytes(16),
          public_key: @valid_cose_key,
          sign_count: 0
        })

      assert Accounts.list_user_passkeys(user2) == []
    end

    test "get_passkey_by_credential_id/1 finds by credential_id" do
      user = user_fixture()
      credential_id = :crypto.strong_rand_bytes(16)

      {:ok, _} =
        Accounts.register_passkey(user, %{
          credential_id: credential_id,
          public_key: @valid_cose_key,
          sign_count: 0
        })

      assert %Passkey{} = Accounts.get_passkey_by_credential_id(credential_id)
      assert Accounts.get_passkey_by_credential_id(:crypto.strong_rand_bytes(16)) == nil
    end

    test "update_passkey_sign_count/2 updates the counter" do
      user = user_fixture()
      credential_id = :crypto.strong_rand_bytes(16)

      {:ok, passkey} =
        Accounts.register_passkey(user, %{
          credential_id: credential_id,
          public_key: @valid_cose_key,
          sign_count: 0
        })

      assert {:ok, updated} = Accounts.update_passkey_sign_count(passkey, 5)
      assert updated.sign_count == 5
    end

    test "delete_user_passkey/2 deletes scoped to the owner" do
      user = user_fixture()
      other_user = user_fixture()

      {:ok, passkey} =
        Accounts.register_passkey(user, %{
          credential_id: :crypto.strong_rand_bytes(16),
          public_key: @valid_cose_key,
          sign_count: 0
        })

      # Other user cannot delete this passkey
      assert {0, _} = Accounts.delete_user_passkey(other_user, passkey.id)

      # Owner can delete
      assert {1, _} = Accounts.delete_user_passkey(user, passkey.id)
      assert Accounts.get_passkey_by_credential_id(passkey.credential_id) == nil
    end
  end

  describe "Passkey.encode_cose_key/1 and decode_cose_key/1" do
    test "round-trips a COSE key map" do
      cose_key = %{
        -3 => <<0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0>>,
        -2 => <<0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10>>,
        -1 => 1,
        1 => 2,
        3 => -7
      }

      encoded = Passkey.encode_cose_key(cose_key)
      decoded = Passkey.decode_cose_key(encoded)

      assert decoded == cose_key
      assert decoded[1] == 2
      assert decoded[3] == -7
    end
  end
end
