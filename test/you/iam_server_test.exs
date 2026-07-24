defmodule You.IAMServerTest do
  use You.DataCase, async: false

  alias You.AccountsFixtures

  describe "verify_token" do
    test "returns user info for valid JWT" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, jwt} = You.JWT.sign(%{sub: user.id, email: user.email, app: "myapp", role: "admin"})

      assert {:ok, info} = GenServer.call(You.IAM.Server, {:verify_token, jwt})
      assert info.user_id == user.id
      assert info.email == user.email
      assert info.role == "admin"
    end

    test "returns error for expired JWT" do
      user = AccountsFixtures.user_fixture()

      {:ok, jwt} =
        You.JWT.sign(%{sub: user.id, email: user.email, app: "myapp", role: "admin"}, -3600)

      assert {:error, :expired} = GenServer.call(You.IAM.Server, {:verify_token, jwt})
    end

    test "returns error for revoked JWT" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, jwt} = You.JWT.sign(%{sub: user.id, email: user.email, app: "myapp", role: "admin"})

      You.JWT.revoke(jwt)

      assert {:error, :revoked} = GenServer.call(You.IAM.Server, {:verify_token, jwt})
    end

    test "returns error for invalid JWT" do
      assert {:error, :invalid_signature} =
               GenServer.call(You.IAM.Server, {:verify_token, "garbage.token.here"})
    end
  end

  describe "get_user" do
    test "returns user info for existing user" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, info} = GenServer.call(You.IAM.Server, {:get_user, user.id})
      assert info.id == user.id
      assert info.email == user.email
    end

    test "returns error for non-existent user" do
      assert {:error, :not_found} = GenServer.call(You.IAM.Server, {:get_user, 999_999})
    end
  end

  describe "revoke_token" do
    test "revokes a JWT so subsequent verify returns revoked" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, jwt} = You.JWT.sign(%{sub: user.id, email: user.email, app: "myapp", role: "admin"})

      assert :ok = GenServer.call(You.IAM.Server, {:revoke_token, jwt})
      assert {:error, :revoked} = GenServer.call(You.IAM.Server, {:verify_token, jwt})
    end
  end

  describe "exchange_code" do
    test "returns JWT for valid auth code" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, code} = You.Accounts.generate_auth_code(user)

      assert {:ok, info} = GenServer.call(You.IAM.Server, {:exchange_code, code})
      assert info.user_id == user.id
      assert info.email == user.email
      assert is_binary(info.jwt)
    end

    test "returns error for invalid auth code" do
      assert {:error, :not_found} = GenServer.call(You.IAM.Server, {:exchange_code, "invalid"})
    end

    test "issues a refresh token" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, code} = You.Accounts.generate_auth_code(user, ["email"])
      assert {:ok, %{refresh_token: rt}} = GenServer.call(You.IAM.Server, {:exchange_code, code})
      assert is_binary(rt)
    end
  end

  describe "client_credentials" do
    test "issues a service JWT for valid client_id and secret" do
      {:ok, app, secret} =
        You.Admin.create_app(%{
          slug: "my-service",
          name: "My Service",
          callback_url: "https://my-service.example.com/cb"
        })

      assert {:ok, %{jwt: jwt}} =
               GenServer.call(You.IAM.Server, {:client_credentials, app.slug, secret})

      assert is_binary(jwt)

      # JWT verifies and carries the expected service claims
      assert {:ok, claims} = You.JWT.verify(jwt)
      assert claims["sub"] == app.slug
      assert claims["app"] == "you"
      assert claims["type"] == "service"
    end

    test "rejects wrong secret" do
      {:ok, app, _secret} =
        You.Admin.create_app(%{
          slug: "my-service",
          name: "My Service",
          callback_url: "https://my-service.example.com/cb"
        })

      assert {:error, :invalid_client} =
               GenServer.call(You.IAM.Server, {:client_credentials, app.slug, "wrong-secret"})
    end

    test "rejects unknown client_id" do
      assert {:error, :invalid_client} =
               GenServer.call(You.IAM.Server, {:client_credentials, "ghost", "some-secret"})
    end

    test "rejects app with no secret configured" do
      # Bypass create_app — insert directly without a secret hash
      {:ok, app} =
        %You.Admin.App{}
        |> You.Admin.App.changeset(%{
          slug: "no-secret-app",
          name: "No Secret",
          callback_url: "https://no-secret.example.com/cb"
        })
        |> You.Repo.insert()

      assert {:error, :invalid_client} =
               GenServer.call(You.IAM.Server, {:client_credentials, app.slug, "any-secret"})
    end
  end

  describe "refresh" do
    test "rotates the refresh token and mints a new JWT for the same scopes" do
      admin = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      You.Repo.update_all(from(u in You.Accounts.User, where: u.id == ^admin.id),
        set: [is_admin: true]
      )

      {:ok, code} = You.Accounts.generate_auth_code(admin, ["email", "roles"])

      {:ok, %{refresh_token: rt1}} = GenServer.call(You.IAM.Server, {:exchange_code, code})
      {:ok, %{refresh_token: rt2, jwt: jwt2}} = GenServer.call(You.IAM.Server, {:refresh, rt1})

      assert rt2 != rt1
      # scopes carried over → role still present
      assert {:ok, %{"role" => "admin"}} = You.JWT.verify(jwt2)
      # old refresh token is single-use — rotated away
      assert {:error, :invalid} = GenServer.call(You.IAM.Server, {:refresh, rt1})
    end

    test "rejects an invalid refresh token" do
      assert {:error, :invalid} = GenServer.call(You.IAM.Server, {:refresh, "nope"})
    end

    test "JWT role reflects is_admin when the roles scope is requested" do
      admin = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      You.Repo.update_all(from(u in You.Accounts.User, where: u.id == ^admin.id),
        set: [is_admin: true]
      )

      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      {:ok, admin_code} = You.Accounts.generate_auth_code(admin, ["email", "roles"])
      {:ok, user_code} = You.Accounts.generate_auth_code(user, ["email", "roles"])

      {:ok, %{jwt: admin_jwt}} = GenServer.call(You.IAM.Server, {:exchange_code, admin_code})
      {:ok, %{jwt: user_jwt}} = GenServer.call(You.IAM.Server, {:exchange_code, user_code})

      assert {:ok, %{"role" => "admin"}} = You.JWT.verify(admin_jwt)
      assert {:ok, %{"role" => "user"}} = You.JWT.verify(user_jwt)
    end
  end
end
