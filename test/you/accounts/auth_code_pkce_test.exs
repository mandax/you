defmodule You.Accounts.AuthCodePKCETest do
  use You.DataCase, async: false

  alias You.Accounts

  setup do
    %{user: You.AccountsFixtures.user_fixture()}
  end

  defp challenge_for(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  test "without a challenge, no verifier is required", %{user: user} do
    {:ok, code} = Accounts.generate_auth_code(user, ["email"])
    assert {:ok, got, ["email"], _app} = Accounts.consume_auth_code(code)
    assert got.id == user.id
  end

  test "with a challenge, the matching verifier succeeds", %{user: user} do
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    {:ok, code} = Accounts.generate_auth_code(user, ["email"], challenge_for(verifier))

    assert {:ok, got, ["email"], _app} = Accounts.consume_auth_code(code, verifier)
    assert got.id == user.id
  end

  test "with a challenge, a wrong verifier is rejected and the code is burned", %{user: user} do
    {:ok, code} = Accounts.generate_auth_code(user, ["email"], challenge_for("right-verifier"))

    assert {:error, :invalid_grant} = Accounts.consume_auth_code(code, "wrong-verifier")
    # single-use: even the correct verifier cannot reuse a burned code
    assert {:error, :not_found} = Accounts.consume_auth_code(code, "right-verifier")
  end

  test "with a challenge, a missing verifier is rejected", %{user: user} do
    {:ok, code} = Accounts.generate_auth_code(user, ["email"], challenge_for("v"))
    assert {:error, :invalid_grant} = Accounts.consume_auth_code(code)
  end
end
