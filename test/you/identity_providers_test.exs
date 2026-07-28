defmodule You.IdentityProvidersTest do
  use You.DataCase, async: false

  alias You.IdentityProviders
  alias You.IdentityProviders.IdentityProvider

  @valid_attrs %{
    "slug" => "okta",
    "display_name" => "Okta",
    "kind" => "generic",
    "client_id" => "abc123",
    "client_secret" => "s3cr3t",
    "issuer" => "https://example.okta.com",
    "authorize_url" => "https://example.okta.com/authorize",
    "token_url" => "https://example.okta.com/token",
    "userinfo_url" => "https://example.okta.com/userinfo",
    "scopes" => "openid email profile"
  }

  describe "create_provider/1" do
    test "creates a provider and encrypts the secret" do
      assert {:ok, %IdentityProvider{} = provider} =
               IdentityProviders.create_provider(@valid_attrs)

      assert provider.slug == "okta"
      assert provider.enabled
      assert is_binary(provider.client_secret)
      refute provider.client_secret == "s3cr3t"
    end

    test "requires slug, display_name, and kind" do
      assert {:error, changeset} = IdentityProviders.create_provider(%{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.slug
      assert "can't be blank" in errors.display_name
      assert "can't be blank" in errors.kind
    end

    test "enforces a unique slug" do
      assert {:ok, _provider} = IdentityProviders.create_provider(@valid_attrs)

      assert {:error, changeset} = IdentityProviders.create_provider(@valid_attrs)
      assert "has already been taken" in errors_on(changeset).slug
    end
  end

  describe "update_provider/2" do
    test "leaves the stored secret untouched when omitted" do
      {:ok, provider} = IdentityProviders.create_provider(@valid_attrs)

      assert {:ok, updated} =
               IdentityProviders.update_provider(provider, %{"display_name" => "Okta (renamed)"})

      assert updated.display_name == "Okta (renamed)"
      assert updated.client_secret == provider.client_secret
      assert IdentityProviders.decrypt_secret(updated) == "s3cr3t"
    end

    test "re-encrypts when a new secret is supplied" do
      {:ok, provider} = IdentityProviders.create_provider(@valid_attrs)

      assert {:ok, updated} =
               IdentityProviders.update_provider(provider, %{"client_secret" => "new-secret"})

      assert updated.client_secret != provider.client_secret
      assert IdentityProviders.decrypt_secret(updated) == "new-secret"
    end
  end

  describe "decrypt_secret/1" do
    test "round-trips the plaintext secret" do
      {:ok, provider} = IdentityProviders.create_provider(@valid_attrs)

      assert IdentityProviders.decrypt_secret(provider) == "s3cr3t"
    end

    test "returns nil when no secret is set" do
      {:ok, provider} =
        IdentityProviders.create_provider(Map.delete(@valid_attrs, "client_secret"))

      assert IdentityProviders.decrypt_secret(provider) == nil
    end
  end

  describe "listing never exposes the plaintext secret" do
    test "list_providers/0 and list_enabled_providers/0 return ciphertext only" do
      {:ok, provider} = IdentityProviders.create_provider(@valid_attrs)

      assert [listed] = IdentityProviders.list_providers()
      assert listed.client_secret == provider.client_secret
      refute listed.client_secret == "s3cr3t"

      assert [enabled] = IdentityProviders.list_enabled_providers()
      assert enabled.client_secret == provider.client_secret
    end

    test "list_enabled_providers/0 excludes disabled providers" do
      {:ok, provider} = IdentityProviders.create_provider(@valid_attrs)
      {:ok, _disabled} = IdentityProviders.update_provider(provider, %{"enabled" => false})

      assert IdentityProviders.list_enabled_providers() == []
      assert length(IdentityProviders.list_providers()) == 1
    end
  end

  describe "get_provider_by_slug/1" do
    test "finds by slug or returns :error" do
      {:ok, provider} = IdentityProviders.create_provider(@valid_attrs)

      assert {:ok, found} = IdentityProviders.get_provider_by_slug("okta")
      assert found.id == provider.id

      assert IdentityProviders.get_provider_by_slug("nonexistent") == :error
    end
  end

  describe "create_provider_from_preset/2" do
    test "expands the google preset's endpoints under the supplied client_id/secret" do
      assert {:ok, provider} =
               IdentityProviders.create_provider_from_preset("google", %{
                 slug: "google",
                 client_id: "gid",
                 client_secret: "gsecret"
               })

      assert provider.display_name == "Google"
      assert provider.kind == "google"
      assert provider.issuer == "https://accounts.google.com"
      assert provider.authorize_url == "https://accounts.google.com/o/oauth2/v2/auth"
      assert provider.token_url == "https://oauth2.googleapis.com/token"
      assert provider.userinfo_url == "https://openidconnect.googleapis.com/v1/userinfo"
      assert provider.scopes == "openid email profile"
      assert provider.client_id == "gid"
      assert IdentityProviders.decrypt_secret(provider) == "gsecret"
    end

    test "lets supplied attrs override the preset template" do
      assert {:ok, provider} =
               IdentityProviders.create_provider_from_preset("microsoft", %{
                 slug: "microsoft",
                 client_id: "mid",
                 client_secret: "msecret",
                 scopes: "openid email profile offline_access"
               })

      assert provider.scopes == "openid email profile offline_access"
    end

    test "returns an error for an unknown preset" do
      assert {:error, :unknown_preset} =
               IdentityProviders.create_provider_from_preset("not-a-preset", %{slug: "x"})
    end
  end

  describe "discover/1" do
    setup do
      test_pid = self()

      plug = fn conn, _opts ->
        send(test_pid, {:discovery_request, conn.request_path})

        body =
          Jason.encode!(%{
            "issuer" => "https://idp.example.com",
            "authorization_endpoint" => "https://idp.example.com/authorize",
            "token_endpoint" => "https://idp.example.com/token",
            "userinfo_endpoint" => "https://idp.example.com/userinfo",
            "scopes_supported" => ["openid", "email", "profile"]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      port = 45_930
      server = start_supervised!({Bandit, plug: plug, port: port, ip: :loopback})
      on_exit(fn -> Process.unlink(server) end)

      %{issuer: "http://localhost:#{port}"}
    end

    test "parses the discovery document into provider attrs", %{issuer: issuer} do
      assert {:ok, attrs} = IdentityProviders.discover(issuer)

      assert_receive {:discovery_request, "/.well-known/openid-configuration"}

      assert attrs.issuer == "https://idp.example.com"
      assert attrs.authorize_url == "https://idp.example.com/authorize"
      assert attrs.token_url == "https://idp.example.com/token"
      assert attrs.userinfo_url == "https://idp.example.com/userinfo"
      assert attrs.scopes == "openid email profile"
    end

    test "surfaces non-200 responses as errors" do
      port = 45_931

      plug = fn conn, _opts -> Plug.Conn.send_resp(conn, 404, "not found") end
      server = start_supervised!({Bandit, plug: plug, port: port, ip: :loopback})
      on_exit(fn -> Process.unlink(server) end)

      assert {:error, _reason} = IdentityProviders.discover("http://localhost:#{port}")
    end
  end

  describe "seed_from_config/0" do
    setup do
      original = Application.get_env(:you, :oidc_providers, %{})
      on_exit(fn -> Application.put_env(:you, :oidc_providers, original) end)
      :ok
    end

    test "inserts providers declared in app config" do
      Application.put_env(:you, :oidc_providers, %{
        "github" => %{
          "display_name" => "GitHub",
          "kind" => "generic",
          "client_id" => "cid",
          "client_secret" => "csecret",
          "authorize_url" => "https://github.com/login/oauth/authorize",
          "token_url" => "https://github.com/login/oauth/access_token",
          "userinfo_url" => "https://api.github.com/user",
          "scopes" => "read:user user:email"
        }
      })

      assert [] = IdentityProviders.list_providers()

      assert [provider] = IdentityProviders.seed_from_config()
      assert provider.slug == "github"
      assert provider.display_name == "GitHub"
      assert IdentityProviders.decrypt_secret(provider) == "csecret"

      assert [_one] = IdentityProviders.list_providers()
    end

    test "is idempotent: a second call does not duplicate or overwrite" do
      Application.put_env(:you, :oidc_providers, %{
        "github" => %{
          "display_name" => "GitHub",
          "kind" => "generic",
          "client_id" => "cid",
          "client_secret" => "csecret"
        }
      })

      assert [_provider] = IdentityProviders.seed_from_config()
      {:ok, existing} = IdentityProviders.get_provider_by_slug("github")

      {:ok, _updated} =
        IdentityProviders.update_provider(existing, %{"display_name" => "Admin-edited name"})

      assert [] = IdentityProviders.seed_from_config()

      assert [only] = IdentityProviders.list_providers()
      assert only.display_name == "Admin-edited name"
    end

    test "does nothing when config is empty" do
      Application.put_env(:you, :oidc_providers, %{})

      assert [] = IdentityProviders.seed_from_config()
      assert [] = IdentityProviders.list_providers()
    end
  end
end
