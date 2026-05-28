defmodule You.JWTTest do
  use You.DataCase, async: false

  alias You.JWT
  alias You.AccountsFixtures

  describe "sign/1 and verify/1" do
    test "signs a token with user claims" do
      user = AccountsFixtures.user_fixture()

      claims = %{
        sub: user.id,
        email: user.email,
        app: "sockeet",
        role: "admin"
      }

      {:ok, signed} = JWT.sign(claims)
      {:ok, verified} = JWT.verify(signed)

      assert verified["sub"] == user.id
      assert verified["email"] == user.email
      assert verified["app"] == "sockeet"
      assert verified["role"] == "admin"
      assert verified["jti"] != nil
      assert verified["iat"] != nil
      assert verified["exp"] != nil
    end

    test "rejects expired tokens" do
      user = AccountsFixtures.user_fixture()

      {:ok, signed} =
        JWT.sign(%{sub: user.id, email: user.email, app: "sockeet", role: "admin"}, -3600)

      assert {:error, :expired} = JWT.verify(signed)
    end

    test "rejects tokens with invalid signature" do
      user = AccountsFixtures.user_fixture()
      {:ok, token} = JWT.sign(%{sub: user.id, email: user.email, app: "sockeet", role: "admin"})

      [header, payload, _sig] = String.split(token, ".")
      corrupted = Enum.join([header, payload, Base.url_encode64("garbage", padding: false)], ".")

      assert {:error, :invalid_signature} = JWT.verify(corrupted)
    end
  end

  describe "revoke/1" do
    test "revokes a token so it cannot be verified" do
      user = AccountsFixtures.user_fixture()
      {:ok, signed} = JWT.sign(%{sub: user.id, email: user.email, app: "sockeet", role: "admin"})

      assert {:ok, _claims} = JWT.verify(signed)
      :ok = JWT.revoke(signed)
      assert {:error, :revoked} = JWT.verify(signed)
    end

    test "other tokens remain valid after revoking one" do
      user_a = AccountsFixtures.user_fixture()
      user_b = AccountsFixtures.user_fixture()

      {:ok, token_a} =
        JWT.sign(%{sub: user_a.id, email: user_a.email, app: "sockeet", role: "admin"})

      {:ok, token_b} =
        JWT.sign(%{sub: user_b.id, email: user_b.email, app: "sockeet", role: "admin"})

      JWT.revoke(token_a)

      assert {:error, :revoked} = JWT.verify(token_a)
      assert {:ok, claims} = JWT.verify(token_b)
      assert claims["email"] == user_b.email
    end
  end
end
