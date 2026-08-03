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

  describe "vault" do
    test "round-trips under the right password" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)

      refute sealed =~ "world"
      assert {:ok, %{"hello" => "world"}} = Vault.open(sealed, @password)
    end

    test "refuses the wrong password" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)

      assert {:error, :wrong_password} = Vault.open(sealed, "not it")
    end

    test "refuses a tampered envelope" do
      sealed = Vault.seal(%{"hello" => "world"}, @password)
      tampered = Jason.decode!(sealed) |> Map.put("kdf", %{"iterations" => 1}) |> Jason.encode!()

      assert {:error, _} = Vault.open(tampered, @password)
    end

    test "refuses anything that is not a bundle" do
      assert {:error, :malformed} = Vault.open("{}", @password)
      assert {:error, :malformed} = Vault.open("not json", @password)
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
  end
end
