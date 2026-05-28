defmodule You.AccountsTest do
  use You.DataCase, async: false

  alias You.Accounts
  alias You.AccountsFixtures

  describe "users" do
    test "registers a user" do
      assert {:ok, user} = Accounts.register_user(%{email: "new@example.com"})
      assert user.email == "new@example.com"
      refute user.confirmed_at
    end

    test "get_user_by_email_and_password" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      assert Accounts.get_user_by_email_and_password(
               user.email,
               AccountsFixtures.valid_user_password()
             )

      refute Accounts.get_user_by_email_and_password(user.email, "wrong")
    end
  end

  describe "2FA" do
    test "generate_totp_setup returns secret and uri" do
      user = AccountsFixtures.user_fixture()
      assert {:ok, setup} = Accounts.generate_totp_setup(user)
      assert setup.secret
      assert setup.uri
      assert String.starts_with?(setup.uri, "otpauth://totp/")
    end

    test "enable_totp with valid code marks 2fa enabled" do
      user = AccountsFixtures.user_fixture()
      {:ok, setup} = Accounts.generate_totp_setup(user)
      valid_code = NimbleTOTP.verification_code(setup.secret)

      assert {:ok, result} = Accounts.enable_totp(setup.user, valid_code)
      assert result.totp_enabled
      assert result.recovery_codes
      assert length(result.recovery_codes) == 8
    end

    test "enable_totp with invalid code returns error" do
      user = AccountsFixtures.user_fixture()
      {:ok, _setup} = Accounts.generate_totp_setup(user)

      assert {:error, :invalid_code} = Accounts.enable_totp(user, "000000")
    end

    test "verify_totp with valid code returns true" do
      user = AccountsFixtures.user_fixture()
      {:ok, setup} = Accounts.generate_totp_setup(user)
      valid_code = NimbleTOTP.verification_code(setup.secret)
      {:ok, _} = Accounts.enable_totp(setup.user, valid_code)

      assert Accounts.verify_totp(setup.user, valid_code)
    end

    test "verify_totp with invalid code returns false" do
      user = AccountsFixtures.user_fixture()
      {:ok, setup} = Accounts.generate_totp_setup(user)
      valid_code = NimbleTOTP.verification_code(setup.secret)
      {:ok, _} = Accounts.enable_totp(setup.user, valid_code)

      refute Accounts.verify_totp(setup.user, "000000")
    end
  end

  describe "auth_code" do
    test "generate_auth_code returns a code string" do
      user = AccountsFixtures.user_fixture()
      assert {:ok, code} = Accounts.generate_auth_code(user)
      assert is_binary(code)
      assert byte_size(code) > 0
    end

    test "consume_auth_code returns user for valid code" do
      user = AccountsFixtures.user_fixture()
      {:ok, code} = Accounts.generate_auth_code(user)
      assert {:ok, consumed} = Accounts.consume_auth_code(code)
      assert consumed.id == user.id
    end

    test "consume_auth_code returns error for invalid code" do
      assert {:error, :not_found} = Accounts.consume_auth_code("invalid-code")
    end

    test "consume_auth_code consumes the code so it cannot be reused" do
      user = AccountsFixtures.user_fixture()
      {:ok, code} = Accounts.generate_auth_code(user)
      {:ok, _} = Accounts.consume_auth_code(code)
      assert {:error, :not_found} = Accounts.consume_auth_code(code)
    end
  end
end
