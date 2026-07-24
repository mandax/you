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
        app: "myapp",
        role: "admin"
      }

      {:ok, signed} = JWT.sign(claims)
      {:ok, verified} = JWT.verify(signed)

      assert verified["sub"] == user.id
      assert verified["email"] == user.email
      assert verified["app"] == "myapp"
      assert verified["role"] == "admin"
      assert verified["jti"] != nil
      assert verified["iat"] != nil
      assert verified["exp"] != nil
    end

    test "rejects expired tokens" do
      user = AccountsFixtures.user_fixture()

      {:ok, signed} =
        JWT.sign(%{sub: user.id, email: user.email, app: "myapp", role: "admin"}, -3600)

      assert {:error, :expired} = JWT.verify(signed)
    end

    test "rejects tokens with invalid signature" do
      user = AccountsFixtures.user_fixture()
      {:ok, token} = JWT.sign(%{sub: user.id, email: user.email, app: "myapp", role: "admin"})

      [header, payload, _sig] = String.split(token, ".")
      corrupted = Enum.join([header, payload, Base.url_encode64("garbage", padding: false)], ".")

      assert {:error, :invalid_signature} = JWT.verify(corrupted)
    end
  end

  describe "key store" do
    setup do
      original = Application.get_env(:you, You.JWT)

      on_exit(fn ->
        if original do
          Application.put_env(:you, You.JWT, original)
        else
          Application.delete_env(:you, You.JWT)
        end
      end)

      :ok
    end

    test "stamps the current kid and EdDSA alg in the header" do
      user = AccountsFixtures.user_fixture()
      {:ok, signed} = JWT.sign(%{sub: user.id})

      assert %{"alg" => "EdDSA", "kid" => "you-ed25519-v1"} = header(signed)
    end

    test "tokens signed by a previous key still verify after rotation" do
      user = AccountsFixtures.user_fixture()
      old_jwk = JOSE.JWK.generate_key({:okp, :Ed25519})
      new_jwk = JOSE.JWK.generate_key({:okp, :Ed25519})

      put_key_store("you-ed25519-v1", %{"you-ed25519-v1" => old_jwk})
      {:ok, old_token} = JWT.sign(%{sub: user.id})

      put_key_store("you-ed25519-v2", %{
        "you-ed25519-v1" => old_jwk,
        "you-ed25519-v2" => new_jwk
      })

      {:ok, new_token} = JWT.sign(%{sub: user.id})

      assert {:ok, claims} = JWT.verify(old_token)
      assert claims["sub"] == user.id
      assert {:ok, claims} = JWT.verify(new_token)
      assert claims["sub"] == user.id
      assert %{"kid" => "you-ed25519-v2"} = header(new_token)
    end

    test "rejects tokens whose kid is no longer in the store" do
      user = AccountsFixtures.user_fixture()
      old_jwk = JOSE.JWK.generate_key({:okp, :Ed25519})

      put_key_store("you-ed25519-v1", %{"you-ed25519-v1" => old_jwk})
      {:ok, old_token} = JWT.sign(%{sub: user.id})

      put_key_store("you-ed25519-v2", %{
        "you-ed25519-v2" => JOSE.JWK.generate_key({:okp, :Ed25519})
      })

      assert {:error, :invalid_signature} = JWT.verify(old_token)
    end

    test "rejects tokens with an unknown kid even if a store key signed them" do
      user = AccountsFixtures.user_fixture()
      {:ok, _} = JWT.sign(%{sub: user.id})
      jwk = Application.get_env(:you, You.JWT)[:keys]["you-ed25519-v1"]

      {_alg, token} =
        JOSE.JWT.sign(jwk, %{"alg" => "EdDSA", "kid" => "unknown"}, %{"sub" => user.id})
        |> JOSE.JWS.compact()

      assert {:error, :invalid_signature} = JWT.verify(token)
    end

    test "legacy tokens without a kid header verify against the store" do
      user = AccountsFixtures.user_fixture()
      {:ok, _} = JWT.sign(%{sub: user.id})
      jwk = Application.get_env(:you, You.JWT)[:keys]["you-ed25519-v1"]

      {_alg, legacy} =
        JOSE.JWT.sign(jwk, %{"sub" => user.id, "exp" => DateTime.to_unix(DateTime.utc_now()) + 60})
        |> JOSE.JWS.compact()

      assert {:ok, claims} = JWT.verify(legacy)
      assert claims["sub"] == user.id
    end

    test "public_jwks lists every key in the store, public parts only" do
      put_key_store("you-ed25519-v2", %{
        "you-ed25519-v1" => JOSE.JWK.generate_key({:okp, :Ed25519}),
        "you-ed25519-v2" => JOSE.JWK.generate_key({:okp, :Ed25519})
      })

      assert %{"keys" => keys} = JWT.public_jwks()
      assert Enum.map(keys, & &1["kid"]) |> Enum.sort() == ["you-ed25519-v1", "you-ed25519-v2"]

      for key <- keys do
        assert key["kty"] == "OKP"
        assert key["crv"] == "Ed25519"
        assert key["use"] == "sig"
        refute Map.has_key?(key, "d")
      end
    end

    defp put_key_store(current_kid, keys) do
      Application.put_env(:you, You.JWT, current_kid: current_kid, keys: keys)
    end

    defp header(signed) do
      [header | _] = String.split(signed, ".")
      Jason.decode!(Base.url_decode64!(header, padding: false))
    end
  end

  describe "revoke/1" do
    test "revokes a token so it cannot be verified" do
      user = AccountsFixtures.user_fixture()
      {:ok, signed} = JWT.sign(%{sub: user.id, email: user.email, app: "myapp", role: "admin"})

      assert {:ok, _claims} = JWT.verify(signed)
      :ok = JWT.revoke(signed)
      assert {:error, :revoked} = JWT.verify(signed)
    end

    test "other tokens remain valid after revoking one" do
      user_a = AccountsFixtures.user_fixture()
      user_b = AccountsFixtures.user_fixture()

      {:ok, token_a} =
        JWT.sign(%{sub: user_a.id, email: user_a.email, app: "myapp", role: "admin"})

      {:ok, token_b} =
        JWT.sign(%{sub: user_b.id, email: user_b.email, app: "myapp", role: "admin"})

      JWT.revoke(token_a)

      assert {:error, :revoked} = JWT.verify(token_a)
      assert {:ok, claims} = JWT.verify(token_b)
      assert claims["email"] == user_b.email
    end
  end
end
