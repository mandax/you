defmodule You.Accounts.PwnedPasswordsTest do
  use ExUnit.Case, async: true

  alias You.Accounts.PwnedPasswords

  describe "count_in_response/2" do
    # SHA1("password") = 5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8
    # prefix 5BAA6, suffix 1E4C9B93F3F0682250B6CF8331B7EE68FD8
    @suffix "1E4C9B93F3F0682250B6CF8331B7EE68FD8"

    test "returns the breach count for a matching suffix" do
      body = "0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n#{@suffix}:9999999\r\nFFFF:3"
      assert PwnedPasswords.count_in_response(body, @suffix) == 9_999_999
    end

    test "is case-insensitive on the suffix" do
      body = "#{String.downcase(@suffix)}:42"
      assert PwnedPasswords.count_in_response(body, @suffix) == 42
    end

    test "returns 0 when the suffix is absent" do
      body = "0018A45C4D1DEF81644B54AB7F969B88D65:1\r\nAAAA:2"
      assert PwnedPasswords.count_in_response(body, @suffix) == 0
    end

    test "handles a padded (count 0) line and empty body" do
      assert PwnedPasswords.count_in_response("#{@suffix}:0", @suffix) == 0
      assert PwnedPasswords.count_in_response("", @suffix) == 0
    end
  end

  describe "validation wiring" do
    test "the check is skipped when disabled (no network call in tests)" do
      # config :you, check_pwned_passwords: false in test.exs — a known-pwned
      # password must still validate, proving no request is made.
      changeset =
        You.Accounts.User.password_changeset(%You.Accounts.User{}, %{
          password: "password12345",
          password_confirmation: "password12345"
        })

      refute Enum.any?(changeset.errors, fn {field, {msg, _}} ->
               field == :password and msg =~ "data breach"
             end)
    end
  end
end
