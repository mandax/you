defmodule You.IdentityProviders.Presets do
  @moduledoc """
  Endpoint templates for well-known identity providers, plus a generic OIDC
  fallback. `expand/2` merges a preset's fixed endpoints under an admin's
  supplied attrs, so only `client_id` and a secret ever need to be hand-typed.

  Two families live here. Most entries are ordinary OIDC providers that the
  generic code path handles as-is. A few — GitHub and Discord — are not OIDC:
  they have no `sub` claim and no standard userinfo endpoint, so they carry a
  `kind` that routes to a dedicated adapter. Adding a preset for a non-OIDC
  provider without also writing its adapter produces a provider that configures
  cleanly and then fails at login.

  Deliberately absent, both for the same reason — a preset that configures
  cleanly and then cannot authenticate is worse than none:

    * X/Twitter returns no email address without elevated access, and You needs
      one to create an account.
    * Sign in with Apple issues no static secret. You download a .p8 key and
      sign an ES256 JWT that expires within six months; there is no fixed
      secret to store, and You has no JWT signing for it.

  Tenant-hosted providers (Auth0, Okta, Keycloak, Authentik, Zitadel) are not
  listed either — their endpoints differ per install, which is what the generic
  preset plus discovery autofill is for.
  """

  alias You.IdentityProviders.IdentityProvider

  # An ordered list, not a map: `names/0` drives the console's preset picker
  # and a map would reorder it.
  @presets [
    {"google",
     %{
       display_name: "Google",
       kind: "google",
       issuer: "https://accounts.google.com",
       authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
       token_url: "https://oauth2.googleapis.com/token",
       userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
       scopes: "openid email profile",
       icon: "google"
     }},
    {"microsoft",
     %{
       display_name: "Microsoft",
       kind: "microsoft",
       issuer: "https://login.microsoftonline.com/common/v2.0",
       authorize_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
       token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
       userinfo_url: "https://graph.microsoft.com/oidc/userinfo",
       scopes: "openid email profile",
       icon: "microsoft"
     }},
    {"github",
     %{
       display_name: "GitHub",
       # Not OIDC: no sub claim, no userinfo endpoint. Handled by
       # You.IdentityProviders.Github.
       kind: "github",
       issuer: "https://github.com",
       authorize_url: "https://github.com/login/oauth/authorize",
       token_url: "https://github.com/login/oauth/access_token",
       userinfo_url: nil,
       scopes: "read:user user:email",
       icon: "github"
     }},
    {"gitlab",
     %{
       display_name: "GitLab",
       kind: "generic",
       issuer: "https://gitlab.com",
       authorize_url: "https://gitlab.com/oauth/authorize",
       token_url: "https://gitlab.com/oauth/token",
       userinfo_url: "https://gitlab.com/oauth/userinfo",
       scopes: "openid email profile",
       icon: "gitlab"
     }},
    {"discord",
     %{
       display_name: "Discord",
       # Not OIDC either: /users/@me, no sub. See You.IdentityProviders.Discord.
       kind: "discord",
       issuer: "https://discord.com",
       authorize_url: "https://discord.com/oauth2/authorize",
       token_url: "https://discord.com/api/oauth2/token",
       userinfo_url: nil,
       scopes: "identify email",
       icon: "discord"
     }},
    {"linkedin",
     %{
       display_name: "LinkedIn",
       kind: "generic",
       issuer: "https://www.linkedin.com/oauth",
       authorize_url: "https://www.linkedin.com/oauth/v2/authorization",
       token_url: "https://www.linkedin.com/oauth/v2/accessToken",
       userinfo_url: "https://api.linkedin.com/v2/userinfo",
       scopes: "openid email profile",
       icon: "linkedin"
     }},
    {"twitch",
     %{
       display_name: "Twitch",
       kind: "generic",
       issuer: "https://id.twitch.tv/oauth2",
       authorize_url: "https://id.twitch.tv/oauth2/authorize",
       token_url: "https://id.twitch.tv/oauth2/token",
       userinfo_url: "https://id.twitch.tv/oauth2/userinfo",
       scopes: "openid user:read:email",
       icon: "twitch"
     }},
    {"slack",
     %{
       display_name: "Slack",
       kind: "generic",
       issuer: "https://slack.com",
       authorize_url: "https://slack.com/openid/connect/authorize",
       token_url: "https://slack.com/api/openid.connect.token",
       userinfo_url: "https://slack.com/api/openid.connect.userInfo",
       scopes: "openid email profile",
       icon: "slack"
     }},
    {"generic",
     %{
       display_name: "OpenID Connect",
       kind: "generic",
       issuer: nil,
       authorize_url: nil,
       token_url: nil,
       userinfo_url: nil,
       scopes: "openid email profile",
       icon: "openid"
     }}
  ]

  @doc """
  Returns the preset names, in the fixed declaration order above.
  """
  def names, do: Enum.map(@presets, &elem(&1, 0))

  @doc """
  Fetches a preset's template attrs by name. Returns `{:ok, attrs}` or
  `:error` for an unknown name.
  """
  def fetch(name) when is_binary(name) do
    case List.keyfind(@presets, name, 0) do
      {^name, preset} -> {:ok, preset}
      nil -> :error
    end
  end

  @doc """
  Expands `attrs` with the named preset's endpoint template, keeping
  whatever `attrs` already supplies (client_id, client_secret, and any
  explicit overrides win over the preset).

  Only keys that name an `IdentityProvider` field are kept from `attrs`;
  anything else is dropped, so a console form or an API caller sending a
  stray key gets a provider rather than a crash.

  Returns `{:ok, expanded_attrs}` or `{:error, :unknown_preset}`.
  """
  def expand(name, attrs) when is_binary(name) and is_map(attrs) do
    case fetch(name) do
      {:ok, preset} -> {:ok, Map.merge(preset, atomize(attrs))}
      :error -> {:error, :unknown_preset}
    end
  end

  # The schema's own field list, so a column added later is accepted without
  # anyone remembering to update a second list here. Anything outside it is
  # dropped rather than converted, so a new or hostile key cannot crash
  # expand/2 (and cannot leak atoms — see String.to_atom/1 in AGENTS.md).
  @known_keys IdentityProvider.__schema__(:fields) |> Enum.map(&Atom.to_string/1)

  defp atomize(attrs) do
    attrs
    |> Enum.flat_map(fn
      {k, v} when is_atom(k) -> [{k, v}]
      {k, v} when is_binary(k) and k in @known_keys -> [{String.to_existing_atom(k), v}]
      _ -> []
    end)
    |> Map.new()
  end
end
