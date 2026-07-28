defmodule You.IdentityProviders.Presets do
  @moduledoc """
  Endpoint templates for well-known identity providers, plus a generic OIDC
  fallback. `expand/2` merges a preset's fixed endpoints under an admin's
  supplied attrs, so only `client_id` and a secret ever need to be hand-typed
  for Google, Microsoft, or Apple.
  """

  @presets %{
    "google" => %{
      display_name: "Google",
      kind: "google",
      issuer: "https://accounts.google.com",
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
      scopes: "openid email profile",
      icon: "google"
    },
    "microsoft" => %{
      display_name: "Microsoft",
      kind: "microsoft",
      issuer: "https://login.microsoftonline.com/common/v2.0",
      authorize_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      userinfo_url: "https://graph.microsoft.com/oidc/userinfo",
      scopes: "openid email profile",
      icon: "microsoft"
    },
    "apple" => %{
      display_name: "Apple",
      kind: "apple",
      issuer: "https://appleid.apple.com",
      authorize_url: "https://appleid.apple.com/auth/authorize",
      token_url: "https://appleid.apple.com/auth/token",
      userinfo_url: nil,
      scopes: "openid email name",
      icon: "apple"
    },
    "generic" => %{
      display_name: "OpenID Connect",
      kind: "generic",
      issuer: nil,
      authorize_url: nil,
      token_url: nil,
      userinfo_url: nil,
      scopes: "openid email profile",
      icon: "openid"
    }
  }

  @doc """
  Returns the preset names, in the fixed declaration order above.
  """
  def names, do: Map.keys(@presets)

  @doc """
  Fetches a preset's template attrs by name. Returns `{:ok, attrs}` or
  `:error` for an unknown name.
  """
  def fetch(name) when is_binary(name), do: Map.fetch(@presets, name)

  @doc """
  Expands `attrs` with the named preset's endpoint template, keeping
  whatever `attrs` already supplies (client_id, client_secret, and any
  explicit overrides win over the preset).

  Returns `{:ok, expanded_attrs}` or `{:error, :unknown_preset}`.
  """
  def expand(name, attrs) when is_binary(name) and is_map(attrs) do
    case fetch(name) do
      {:ok, preset} -> {:ok, Map.merge(preset, atomize(attrs))}
      :error -> {:error, :unknown_preset}
    end
  end

  defp atomize(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  end
end
