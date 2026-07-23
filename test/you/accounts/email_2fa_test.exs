defmodule You.Accounts.Email2faTest do
  use You.DataCase, async: false

  alias You.Accounts

  # Drains delivered emails until the 2FA code email is found (a fixture may
  # have queued a confirmation email first).
  defp code_from_email do
    receive do
      {:email, email} ->
        case Regex.run(~r/code is:\s*(\d{6})/, email.text_body || "") do
          [_, code] -> code
          _ -> code_from_email()
        end
    after
      200 -> flunk("no email 2FA code was delivered")
    end
  end

  test "enable / send / verify (single-use) / disable" do
    user = You.AccountsFixtures.user_fixture()

    {:ok, user} = Accounts.enable_email_2fa(user)
    assert user.email_2fa_enabled

    assert :ok = Accounts.send_email_2fa_code(user)
    code = code_from_email()

    assert Accounts.verify_email_2fa_code(user, code) == :ok
    # single-use: the same code can't be reused
    assert Accounts.verify_email_2fa_code(user, code) == {:error, :invalid_code}

    {:ok, user} = Accounts.disable_email_2fa(user)
    refute user.email_2fa_enabled
  end

  test "a wrong code is rejected" do
    user = You.AccountsFixtures.user_fixture()
    assert :ok = Accounts.send_email_2fa_code(user)
    _ = code_from_email()

    assert Accounts.verify_email_2fa_code(user, "000000") == {:error, :invalid_code}
  end

  test "sending a new code supersedes the previous one" do
    user = You.AccountsFixtures.user_fixture()
    Accounts.send_email_2fa_code(user)
    old = code_from_email()

    Accounts.send_email_2fa_code(user)
    new = code_from_email()

    assert Accounts.verify_email_2fa_code(user, old) == {:error, :invalid_code}
    assert Accounts.verify_email_2fa_code(user, new) == :ok
  end
end
