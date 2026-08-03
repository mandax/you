defmodule You.ConfigBundleTest do
  @moduledoc """
  A configuration bundle has to survive the trip to a different instance: one
  that shares no `secret_key_base`, and therefore cannot read anything the
  source encrypted with it.
  """
  use You.DataCase, async: false

  alias You.Admin
  alias You.Config.Bundle
  alias You.Config.Vault
  alias You.IdentityProviders
  alias You.Settings

  @password "correct horse battery staple"

  defp rotate_instance_key do
    config = Application.fetch_env!(:you, YouWeb.Endpoint)
    original = config[:secret_key_base]

    Application.put_env(
      :you,
      YouWeb.Endpoint,
      Keyword.put(config, :secret_key_base, Base.encode64(:crypto.strong_rand_bytes(48)))
    )

    on_exit(fn ->
      Application.put_env(
        :you,
        YouWeb.Endpoint,
        Keyword.put(Application.fetch_env!(:you, YouWeb.Endpoint), :secret_key_base, original)
      )
    end)
  end

  defp seal_with_pbkdf2(payload, password, iterations \\ 10) do
    salt = :crypto.strong_rand_bytes(16)
    iv = :crypto.strong_rand_bytes(12)
    key = :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)

    header = %{
      "format" => "you.config.v1",
      "kdf" => %{"algorithm" => "pbkdf2-hmac-sha256", "iterations" => iterations},
      "salt" => Base.encode64(salt),
      "iv" => Base.encode64(iv)
    }

    plaintext = Jason.encode!(payload)
    aad = Jason.encode!(header)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)

    header
    |> Map.put("tag", Base.encode64(tag))
    |> Map.put("payload", Base.encode64(ciphertext))
    |> Jason.encode!()
  end

  describe "vault" do
    test "round-trips under the right password, sealed with argon2id" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)

      refute sealed =~ "world"
      assert Jason.decode!(sealed)["kdf"]["algorithm"] == "argon2id"
      assert {:ok, %{"hello" => "world"}} = Vault.open(sealed, @password)
    end

    test "a bundle sealed with the default argon2id parameters opens under its own bounds" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)
      kdf = Jason.decode!(sealed)["kdf"]

      assert kdf == %{
               "algorithm" => "argon2id",
               "m_cost" => 16,
               "t_cost" => 16,
               "parallelism" => 4
             }

      assert {:ok, %{"hello" => "world"}} = Vault.open(sealed, @password)
    end

    test "a bundle sealed with the older pbkdf2 kdf still opens" do
      sealed = seal_with_pbkdf2(%{"hello" => "world"}, @password)

      assert {:ok, %{"hello" => "world"}} = Vault.open(sealed, @password)
    end

    test "refuses the wrong password" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)

      assert {:error, :wrong_password} = Vault.open(sealed, "not it")
    end

    test "refuses the wrong password against a pbkdf2 bundle" do
      sealed = seal_with_pbkdf2(%{"hello" => "world"}, @password)

      assert {:error, :wrong_password} = Vault.open(sealed, "not it")
    end

    test "refuses a tampered envelope" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)
      tampered = Jason.decode!(sealed) |> Map.put("kdf", %{"iterations" => 1}) |> Jason.encode!()

      assert {:error, _} = Vault.open(tampered, @password)
    end

    test "refuses a tampered algorithm" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)

      tampered =
        sealed
        |> Jason.decode!()
        |> update_in(["kdf", "algorithm"], fn _ -> "pbkdf2-hmac-sha256" end)
        |> put_in(["kdf", "iterations"], 10)
        |> Jason.encode!()

      assert {:error, _} = Vault.open(tampered, @password)
    end

    test "refuses a tampered cost parameter" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)

      tampered =
        sealed
        |> Jason.decode!()
        |> put_in(["kdf", "t_cost"], 1)
        |> Jason.encode!()

      assert {:error, _} = Vault.open(tampered, @password)
    end

    test "refuses anything that is not a bundle" do
      assert {:error, :malformed} = Vault.open("{}", @password)
      assert {:error, :malformed} = Vault.open("not json", @password)
    end

    test "refuses to seal under a password shorter than the minimum" do
      short = String.duplicate("a", Vault.min_password_length() - 1)

      assert_raise ArgumentError, fn -> Vault.seal(%{"hello" => "world"}, short) end
    end

    test "accepts a password exactly at the minimum" do
      exact = String.duplicate("a", Vault.min_password_length())

      assert Vault.seal(%{"hello" => "world"}, exact)
    end
  end

  describe "round trip to another instance" do
    setup do
      {:ok, _app, _secret} =
        Admin.create_app(%{
          slug: "portable",
          name: "Portable App",
          callback_url: "https://portable.example.com/cb",
          brand_color: "#7c3aed",
          allowed_roles: ["user", "admin"]
        })

      {:ok, _provider} =
        IdentityProviders.create_provider(%{
          "slug" => "acme",
          "display_name" => "Acme",
          "kind" => "oidc",
          "client_id" => "acme-client",
          "client_secret" => "s3cret-from-source",
          "issuer" => "https://acme.example.com"
        })

      {:ok, _endpoint} =
        You.Webhooks.create_endpoint(%{
          "url" => "https://hooks.example.com/you",
          "events" => ["login:attempt"]
        })

      Settings.set(:jwt_expiry_hours, 6)
      :ok
    end

    test "carries settings, apps, providers and webhooks through the password" do
      sealed = Bundle.export() |> Vault.seal(@password)

      refute sealed =~ "s3cret-from-source"
      refute sealed =~ "portable.example.com"

      {:ok, payload} = Vault.open(sealed, @password)

      assert payload["settings"]["jwt_expiry_hours"] == 6
      assert [%{"slug" => "portable", "brand_color" => "#7c3aed"}] = payload["apps"]

      assert [%{"slug" => "acme", "client_secret" => "s3cret-from-source"}] =
               payload["identity_providers"]

      assert [%{"url" => "https://hooks.example.com/you"}] = payload["webhook_endpoints"]
    end

    test "the provider secret is usable after import on an instance with a different key" do
      sealed = Bundle.export() |> Vault.seal(@password)

      # Everything the source encrypted is now unreadable: this is the
      # destination instance.
      Repo.delete_all(You.IdentityProviders.IdentityProvider)
      Repo.delete_all(You.Admin.App)
      rotate_instance_key()

      {:ok, payload} = Vault.open(sealed, @password)
      {:ok, summary} = Bundle.import(payload)

      assert summary.apps == 1
      assert summary.identity_providers == 1

      provider = Repo.get_by!(You.IdentityProviders.IdentityProvider, slug: "acme")

      assert {:ok, "s3cret-from-source"} =
               You.IdentityProviders.Crypto.fetch(provider.client_secret)
    end

    test "import upserts and never deletes" do
      sealed = Bundle.export() |> Vault.seal(@password)

      {:ok, _} =
        Admin.create_app(%{
          slug: "local-only",
          name: "Local Only",
          callback_url: "https://local.example.com/cb"
        })
        |> case do
          {:ok, app, _secret} -> {:ok, app}
          other -> other
        end

      {:ok, payload} = Vault.open(sealed, @password)
      {:ok, _summary} = Bundle.import(payload)

      assert Repo.get_by(You.Admin.App, slug: "local-only")
      assert Repo.get_by(You.Admin.App, slug: "portable")
    end

    test "a settings key that must stay environment-only is ignored, not raised on" do
      payload = %{
        "version" => 1,
        "settings" => %{"secret_key_base" => "should-never-be-settable"}
      }

      assert {:ok, summary} = Bundle.import(payload)
      assert summary.settings == 0
    end

    test "a legitimate bundle previews cleanly before it is applied" do
      sealed = Bundle.export() |> Vault.seal(@password)
      {:ok, payload} = Vault.open(sealed, @password)

      assert {:ok, preview} = Bundle.preview(payload)
      refute preview.privileged?
      assert preview.ignored_settings == []

      app = Enum.find(preview.apps, &(&1.slug == "portable"))
      assert app.action == :unchanged
      refute app.privileged?

      provider = Enum.find(preview.identity_providers, &(&1.slug == "acme"))
      assert provider.action == :unchanged

      endpoint =
        Enum.find(preview.webhook_endpoints, &(&1.url == "https://hooks.example.com/you"))

      assert endpoint.action == :unchanged

      assert {:ok, _summary} = Bundle.import(payload)
    end
  end

  describe "instance identity keys" do
    test "erlang_cookie, api_token and scim_bearer_token are excluded from export" do
      Settings.set(:erlang_cookie, "source-cookie")
      Settings.set(:api_token, "source-api-token")
      Settings.set(:scim_bearer_token, "source-scim-token")

      settings = Bundle.export()["settings"]

      refute Map.has_key?(settings, "erlang_cookie")
      refute Map.has_key?(settings, "api_token")
      refute Map.has_key?(settings, "scim_bearer_token")
    end

    test "a bundle carrying identity keys does not apply them, and the preview says so" do
      payload = %{
        "version" => 1,
        "settings" => %{
          "erlang_cookie" => "attacker-cookie",
          "api_token" => "attacker-api-token",
          "scim_bearer_token" => "attacker-scim-token"
        }
      }

      assert {:ok, preview} = Bundle.preview(payload)
      assert preview.privileged?

      assert Enum.sort(preview.ignored_settings) == [
               "api_token",
               "erlang_cookie",
               "scim_bearer_token"
             ]

      assert preview.settings == []

      assert {:ok, summary} = Bundle.import(payload)
      assert summary.settings == 0
      assert Settings.get(:erlang_cookie) == ""
      assert Settings.get(:api_token) == ""
      assert Settings.get(:scim_bearer_token) == ""
    end
  end

  describe "a hostile bundle's privileged changes are visible in the preview" do
    test "flags api_token, audit_webhook_url, a first-party app and an enabled provider" do
      payload = %{
        "version" => 1,
        "settings" => %{
          "api_token" => "stolen-token",
          "audit_webhook_url" => "https://attacker.example.com/audit"
        },
        "apps" => [
          %{
            "slug" => "evil-app",
            "name" => "Evil App",
            "callback_url" => "https://attacker.example.com/cb",
            "first_party" => true
          }
        ],
        "identity_providers" => [
          %{
            "slug" => "evil-idp",
            "display_name" => "Evil IdP",
            "kind" => "oidc",
            "authorize_url" => "https://attacker.example.com/authorize",
            "token_url" => "https://attacker.example.com/token",
            "userinfo_url" => "https://attacker.example.com/userinfo",
            "enabled" => true
          }
        ]
      }

      assert {:ok, preview} = Bundle.preview(payload)
      assert preview.privileged?

      assert "api_token" in preview.ignored_settings

      audit_setting = Enum.find(preview.settings, &(&1.key == "audit_webhook_url"))
      assert audit_setting.privileged?
      assert audit_setting.status == :set

      app = Enum.find(preview.apps, &(&1.slug == "evil-app"))
      assert app.action == :create
      assert app.privileged?
      assert app.callback_url == "https://attacker.example.com/cb"

      provider = Enum.find(preview.identity_providers, &(&1.slug == "evil-idp"))
      assert provider.action == :create
      assert provider.privileged?
      assert provider.authorize_url == "https://attacker.example.com/authorize"
    end
  end

  describe "malformed payloads never crash preview/1 or import/1" do
    test "a settings map given as a list" do
      payload = %{"version" => 1, "settings" => []}

      assert {:error, :malformed} = Bundle.preview(payload)
      assert {:error, :malformed} = Bundle.import(payload)
    end

    test "an apps list given as a map" do
      payload = %{"version" => 1, "apps" => %{}}

      assert {:error, :malformed} = Bundle.preview(payload)
      assert {:error, :malformed} = Bundle.import(payload)
    end

    test "a non-numeric string for an integer setting" do
      payload = %{"version" => 1, "settings" => %{"smtp_port" => "x"}}

      assert {:error, :malformed} = Bundle.preview(payload)
      assert {:error, :malformed} = Bundle.import(payload)
    end

    test "a float value for a setting" do
      payload = %{"version" => 1, "settings" => %{"session_expiry_hours" => 24.5}}

      assert {:error, :malformed} = Bundle.preview(payload)
      assert {:error, :malformed} = Bundle.import(payload)
    end

    test "an app entry that is not a map" do
      payload = %{"version" => 1, "apps" => ["not-a-map"]}

      assert {:error, :malformed} = Bundle.preview(payload)
      assert {:error, :malformed} = Bundle.import(payload)
    end
  end

  describe "vault bounds" do
    test "refuses a non-map kdf instead of raising" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)
      tampered = Jason.decode!(sealed) |> Map.put("kdf", "not-a-map") |> Jason.encode!()

      assert {:error, :malformed} = Vault.open(tampered, @password)
    end

    test "refuses zero pbkdf2 iterations instead of raising" do
      sealed = seal_with_pbkdf2(%{"hello" => "world"}, @password)

      tampered =
        Jason.decode!(sealed)
        |> Map.update!("kdf", &Map.put(&1, "iterations", 0))
        |> Jason.encode!()

      assert {:error, :malformed} = Vault.open(tampered, @password)
    end

    test "refuses negative pbkdf2 iterations instead of raising" do
      sealed = seal_with_pbkdf2(%{"hello" => "world"}, @password)

      tampered =
        Jason.decode!(sealed)
        |> Map.update!("kdf", &Map.put(&1, "iterations", -1))
        |> Jason.encode!()

      assert {:error, :malformed} = Vault.open(tampered, @password)
    end

    test "refuses an unreasonably large pbkdf2 iteration count" do
      sealed = seal_with_pbkdf2(%{"hello" => "world"}, @password)

      tampered =
        Jason.decode!(sealed)
        |> Map.update!("kdf", &Map.put(&1, "iterations", 50_000_000))
        |> Jason.encode!()

      assert {:error, :malformed} = Vault.open(tampered, @password)
    end

    test "refuses zero argon2 m_cost instead of raising" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)

      tampered =
        Jason.decode!(sealed)
        |> Map.update!("kdf", &Map.put(&1, "m_cost", 0))
        |> Jason.encode!()

      assert {:error, :malformed} = Vault.open(tampered, @password)
    end

    test "refuses an unreasonably large argon2 m_cost" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)

      tampered =
        Jason.decode!(sealed)
        |> Map.update!("kdf", &Map.put(&1, "m_cost", 1_000_000))
        |> Jason.encode!()

      assert {:error, :malformed} = Vault.open(tampered, @password)
    end
  end
end
