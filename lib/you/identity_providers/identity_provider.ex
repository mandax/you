defmodule You.IdentityProviders.IdentityProvider do
  @moduledoc """
  A configured OIDC identity provider used to federate login to You.

  `client_secret` is stored encrypted (see `You.IdentityProviders.Crypto`).
  The changeset accepts a plaintext secret under `"client_secret"` (or
  `:client_secret`) and encrypts it into this binary field directly — it is
  never cast as-is, so the plaintext never lands on the struct. Omit it to
  leave a previously stored secret untouched.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias You.IdentityProviders.Crypto

  schema "identity_providers" do
    field :slug, :string
    field :display_name, :string
    field :kind, :string
    field :client_id, :string
    field :client_secret, :binary
    field :issuer, :string
    field :authorize_url, :string
    field :token_url, :string
    field :userinfo_url, :string
    field :scopes, :string
    field :icon, :string
    field :enabled, :boolean, default: true
    field :sort_order, :integer, default: 0

    timestamps()
  end

  @doc """
  Builds a changeset for creating or updating a provider.
  """
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :slug,
      :display_name,
      :kind,
      :client_id,
      :issuer,
      :authorize_url,
      :token_url,
      :userinfo_url,
      :scopes,
      :icon,
      :enabled,
      :sort_order
    ])
    |> validate_required([:slug, :display_name, :kind])
    |> unique_constraint(:slug)
    |> put_encrypted_secret(attrs)
  end

  defp put_encrypted_secret(changeset, attrs) do
    case fetch_secret(attrs) do
      {:ok, secret} when is_binary(secret) and secret != "" ->
        put_change(changeset, :client_secret, Crypto.encrypt(secret))

      _ ->
        changeset
    end
  end

  defp fetch_secret(attrs) do
    case Map.fetch(attrs, "client_secret") do
      {:ok, secret} -> {:ok, secret}
      :error -> Map.fetch(attrs, :client_secret)
    end
  end
end
