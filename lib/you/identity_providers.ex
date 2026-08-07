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

  alias You.IdentityProviders.{Crypto, Discovery, IdentityProvider, LoginFlow, Presets}
  alias You.Repo

  @ctx_salt "you.identity_providers.login_ctx"
  @ctx_max_age_seconds 300

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
  Like `decrypt_secret/1`, but reports an unreadable secret instead of raising.

  `{:ok, nil}` is a provider that legitimately has no secret (a public client);
  `{:error, :undecryptable}` is one whose stored ciphertext will not open under
  the current `secret_key_base`, which happens after a key rotation and needs
  the admin to re-enter the secret. Login paths must distinguish the two.
  """
  def fetch_secret(%IdentityProvider{client_secret: nil}), do: {:ok, nil}

  def fetch_secret(%IdentityProvider{client_secret: ciphertext}) do
    case Crypto.fetch(ciphertext) do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, :undecryptable}
    end
  end

  @doc """
  Fetches and parses the discovery document at `issuer` (see
  `You.IdentityProviders.Discovery`). Returns `{:ok, attrs}` or
  `{:error, reason}`.
  """
  def discover(issuer) when is_binary(issuer), do: Discovery.fetch(issuer)

  @doc """
  Starts a federated login flow for `provider`, persisting `ctx` (a
  string-keyed map of `callback_url`, `scopes`, `code_challenge`,
  `branding_app_slug`, and the consumer app's own OAuth `state` — distinct
  from the `state` this function returns) behind that opaque `state`.

  Returns `{state, nonce}`: `state` goes upstream to the IdP as the OIDC
  `state` param, and `nonce` must be set as the binding cookie on the
  response to the initiating browser (see `LoginFlow`).
  """
  def start_login_flow(provider, ctx) when is_binary(provider) and is_map(ctx) do
    {state, nonce, flow} = LoginFlow.build(provider, ctx)
    Repo.insert!(flow)
    {state, nonce}
  end

  @doc """
  Consumes a login flow started by `start_login_flow/2`: looks up `state` for
  `provider`, deletes it (single-use, whether or not what follows succeeds),
  and checks `nonce` — the value read from the binding cookie on the callback
  request — against the stored hash in constant time.

  A `state` that is unknown, expired, minted for a different provider, or not
  validly encoded, and a `state` that is otherwise valid but paired with a
  missing or mismatched `nonce`, all return the same
  `{:error, :state_mismatch}` — none of them is the browser that started the
  flow, and none of them should learn which check is the one that failed.

  Returns `{:ok, ctx}` (string-keyed map) on success.
  """
  def consume_login_flow(provider, state, nonce) when is_binary(provider) and is_binary(state) do
    case find_and_delete_flow(state, provider) do
      nil -> {:error, :state_mismatch}
      flow -> verify_nonce(flow, nonce)
    end
  end

  def consume_login_flow(_provider, _state, _nonce), do: {:error, :state_mismatch}

  # A double-click on the IdP return, a browser retry, or a link prefetch can
  # present the same `state` twice at once. Find-then-delete would let both
  # readers see the row before either deletes it, so the loser's `delete!`
  # raises `Ecto.StaleEntryError` instead of getting a clean refusal — a
  # single `DELETE … RETURNING` makes "found and deleted" atomic: at most one
  # concurrent caller gets the row back.
  defp find_and_delete_flow(state, provider) do
    with {:ok, query} <- LoginFlow.verify_query(state, provider),
         {1, [flow]} <- Repo.delete_all(from f in query, select: f) do
      flow
    else
      _ -> nil
    end
  end

  defp verify_nonce(flow, nonce) do
    if LoginFlow.nonce_matches?(flow, nonce) do
      {:ok, LoginFlow.ctx(flow)}
    else
      {:error, :state_mismatch}
    end
  end

  @doc """
  Deletes flow records past `LoginFlow.validity_in_minutes/0`: the ones
  nobody came back from the IdP for. Called from `You.Accounts.JtiCleanup`.
  """
  def cleanup_expired_login_flows do
    threshold = DateTime.add(DateTime.utc_now(), -LoginFlow.validity_in_minutes() * 60, :second)

    Repo.delete_all(from f in LoginFlow, where: f.inserted_at < ^threshold)
  end

  @doc """
  Signs `attrs` (a map, atom or string keys) into a short-lived opaque blob
  suitable for the `ctx` query param on `/auth/:provider` — the carrier #121
  uses to hand a login flow from an app host's session to canonical without
  one being able to read or forge the other's session.

  Keys are normalised to strings on the way in: `verify_ctx/1`, `resolve_ctx/2`
  and `LoginFlow.ctx/1` all read string keys (`ctx["callback_url"]`, …), same
  as everywhere else a `ctx` map is read. A caller minting one with atom keys
  would otherwise round-trip through `Jason` and come back with the wrong
  keys — every read misses, `ctx["callback_url"]` is `nil`, and the flow
  fails closed with no error to point at why.

  Not yet linked from anywhere a user can reach: today `/auth/:provider`
  always has a same-host session to read `ctx` from instead, so no caller
  mints one. Kept here, and consumed by `verify_ctx/1` when present, so #121
  only has to change where the social button links.
  """
  def sign_ctx(attrs) when is_map(attrs) do
    normalized = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    Phoenix.Token.sign(YouWeb.Endpoint, @ctx_salt, normalized)
  end

  @doc """
  Verifies a `ctx` blob minted by `sign_ctx/1`. Returns `{:ok, attrs}` or
  `:error` on a missing, tampered, or expired (5 minute) signature.
  """
  def verify_ctx(signed) when is_binary(signed) do
    case Phoenix.Token.verify(YouWeb.Endpoint, @ctx_salt, signed, max_age: @ctx_max_age_seconds) do
      {:ok, attrs} when is_map(attrs) -> {:ok, attrs}
      _ -> :error
    end
  end

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
