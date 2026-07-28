defmodule You.IdentityProviders do
  @moduledoc """
  Configured OIDC identity providers used to federate login to You.

  Providers used to live only in `config :you, :oidc_providers`
  (`config/config.exs`); they are now rows in the `identity_providers` table,
  editable at runtime instead of requiring a redeploy. `seed_from_config/0`
  migrates any providers still declared in app config into the table on
  boot, so existing deployments keep working with no manual step.

  Client secrets are stored encrypted (`You.IdentityProviders.Crypto`);
  `list_providers/0`, `list_enabled_providers/0`, and `get_provider_by_slug/1`
  never decrypt them — only `decrypt_secret/1` does, and only the OIDC login
  flow that needs the plaintext to hit the token endpoint should call it.
  """

  import Ecto.Query, warn: false

  alias You.IdentityProviders.{Crypto, Discovery, IdentityProvider, Presets}
  alias You.Repo

  @doc """
  Lists all providers, ordered by `sort_order` then `slug`.
  """
  def list_providers do
    Repo.all(from p in IdentityProvider, order_by: [asc: p.sort_order, asc: p.slug])
  end

  @doc """
  Lists only enabled providers, ordered by `sort_order` then `slug`. This is
  what the login screen should call.
  """
  def list_enabled_providers do
    Repo.all(
      from p in IdentityProvider,
        where: p.enabled == true,
        order_by: [asc: p.sort_order, asc: p.slug]
    )
  end

  @doc """
  Fetches a single provider by id, raising if it does not exist.
  """
  def get_provider!(id), do: Repo.get!(IdentityProvider, id)

  @doc """
  Fetches a single provider by slug. Returns `{:ok, provider}` or `:error`.
  """
  def get_provider_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(IdentityProvider, slug: slug) do
      nil -> :error
      provider -> {:ok, provider}
    end
  end

  @doc """
  Builds a changeset for tracking provider form state, without persisting.
  """
  def change_provider(%IdentityProvider{} = provider, attrs \\ %{}) do
    IdentityProvider.changeset(provider, attrs)
  end

  @doc """
  Creates a provider. Returns `{:ok, provider}` or `{:error, changeset}`.
  """
  def create_provider(attrs) do
    %IdentityProvider{}
    |> IdentityProvider.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a provider from a named preset (see `You.IdentityProviders.Presets`),
  merging `attrs` (typically `client_id` and a secret) over the preset's
  endpoint template. Returns `{:ok, provider}`, `{:error, changeset}`, or
  `{:error, :unknown_preset}`.
  """
  def create_provider_from_preset(preset_name, attrs) when is_binary(preset_name) do
    with {:ok, expanded} <- Presets.expand(preset_name, attrs) do
      create_provider(expanded)
    end
  end

  @doc """
  Updates an existing provider. Omit `client_secret` in `attrs` to leave the
  stored secret untouched. Returns `{:ok, provider}` or `{:error, changeset}`.
  """
  def update_provider(%IdentityProvider{} = provider, attrs) do
    provider
    |> IdentityProvider.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a provider. Returns `{:ok, provider}` or `{:error, changeset}`.
  """
  def delete_provider(%IdentityProvider{} = provider) do
    Repo.delete(provider)
  end

  @doc """
  Decrypts and returns a provider's plaintext client secret, or `nil` when
  none is set. Callers must not log or otherwise persist the result.
  """
  def decrypt_secret(%IdentityProvider{client_secret: nil}), do: nil
  def decrypt_secret(%IdentityProvider{client_secret: ciphertext}), do: Crypto.decrypt(ciphertext)

  @doc """
  Fetches and parses the discovery document at `issuer` (see
  `You.IdentityProviders.Discovery`). Returns `{:ok, attrs}` or
  `{:error, reason}`.
  """
  def discover(issuer) when is_binary(issuer), do: Discovery.fetch(issuer)

  @doc """
  Seeds the `identity_providers` table from `config :you, :oidc_providers`
  (see `config/config.exs`). Idempotent: a provider whose slug already has a
  row is left untouched, so this is safe to call on every boot and will not
  clobber providers an admin has since edited or added through the table
  directly.

  Returns the list of newly inserted providers.
  """
  def seed_from_config do
    :you
    |> Application.get_env(:oidc_providers, %{})
    |> Enum.reject(fn {slug, _config} ->
      Repo.exists?(from p in IdentityProvider, where: p.slug == ^slug)
    end)
    |> Enum.map(fn {slug, config} -> seed_one(slug, config) end)
  end

  defp seed_one(slug, config) do
    attrs = %{
      slug: slug,
      display_name: config["display_name"] || String.capitalize(slug),
      kind: config["kind"] || slug,
      client_id: config["client_id"],
      client_secret: config["client_secret"],
      issuer: config["issuer"],
      authorize_url: config["authorize_url"],
      token_url: config["token_url"],
      userinfo_url: config["userinfo_url"],
      scopes: config["scopes"],
      icon: config["icon"] || slug
    }

    {:ok, provider} = create_provider(attrs)
    provider
  end
end
