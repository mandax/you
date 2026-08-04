defmodule You.Settings do
  @moduledoc """
  Reads instance configuration from the `settings` table, cached per node.

  Defaults:
  - `session_expiry_hours`: 24
  - `jwt_expiry_hours`: 1
  - `code_expiry_minutes`: 5
  - `magic_link_expiry_minutes`: 15
  - `erlang_cookie`: ""
  - `erlang_node_name`: "you@you.example.com"
  - `epmd_port`: 4369
  - `scim_bearer_token`: ""
  - `audit_webhook_url`: ""
  - `you_mode`: "multi"
  - `smtp_host`, `smtp_username`, `smtp_password`, `mail_from`: ""
  - `smtp_port`: 587
  - `api_token`: ""
  - `analytics_src`, `analytics_domain`: ""

  Every key here is reachable from `deploy environment` and the console alike:
  the environment seeds a key's row the first time an instance boots without
  one (`You.Settings.EnvSeed`); once that row exists, the console owns it and
  a redeploy with the same environment variable never clobbers a later edit.

  A handful of bootstrap and key-material values — `DATABASE_PATH`,
  `SECRET_KEY_BASE`, `JWT_SIGNING_KEY`, `JWT_KEY_ID`, `JWT_PREVIOUS_KEYS`,
  `PHX_HOST`, `PHX_SCHEME`, `POOL_SIZE`, `BIND_IP` — are deliberately absent
  from `@defaults` and rejected by `set/2`: putting them behind a console
  login is either circular (the login depends on them) or a way to lock an
  operator out.
  """

  alias You.Settings.Setting
  alias You.Repo

  @defaults %{
    session_expiry_hours: 24,
    jwt_expiry_hours: 1,
    code_expiry_minutes: 5,
    magic_link_expiry_minutes: 15,
    erlang_cookie: "",
    erlang_node_name: "you@you.example.com",
    epmd_port: 4369,
    scim_bearer_token: "",
    audit_webhook_url: "",
    onboarding_completed: false,
    feature_passkeys: true,
    feature_magic_link: true,
    feature_social_login: true,
    feature_webhooks: true,
    feature_landing_page: true,
    you_mode: "multi",
    smtp_host: "",
    smtp_port: 587,
    smtp_username: "",
    smtp_password: "",
    mail_from: "",
    api_token: "",
    analytics_src: "",
    analytics_domain: ""
  }

  @doc """
  Environment variables that must never be settable from the console.

  Bootstrap or key material: `DATABASE_PATH` names the file the console runs
  against, `SECRET_KEY_BASE`/`JWT_*` sign the sessions and tokens a console
  login depends on, and `PHX_HOST`/`PHX_SCHEME`/`POOL_SIZE`/`BIND_IP` shape
  how the instance is reached at all. `set/2` rejects these atoms outright, so
  a future key added under one of these names cannot become console-editable
  by accident.
  """
  @forbidden_keys ~w(
    database_path secret_key_base jwt_signing_key jwt_key_id jwt_previous_keys
    phx_host phx_scheme pool_size bind_ip
  )a

  def forbidden_keys, do: @forbidden_keys

  # Toggled from the feature screen. Everything else in @defaults is a tuning
  # value, not a switch.
  #
  # Second factors are deliberately absent. TOTP and email 2FA are security
  # controls, not optional surface: a switch that turns them off is a
  # downgrade attack with an admin-friendly label on it, and it would strand
  # every account already enrolled.
  @features [
    :feature_passkeys,
    :feature_magic_link,
    :feature_social_login,
    :feature_webhooks,
    :feature_landing_page
  ]

  @doc "The optional features an admin can switch off."
  def features, do: @features

  @doc """
  Whether an optional feature is on.

  Unknown keys are off rather than raising: a feature removed from the code
  should not take the console down with it.
  """
  def enabled?(key) when is_atom(key) do
    key in @features and get(key) == true
  end

  @doc """
  Returns the value for a setting key, falling back to the default if not
  configured, cast to the default's type.

  Cached in `:persistent_term` and refreshed by `set/2`, because these are read
  on hot paths — `enabled_methods/1` alone asks three times per login page
  render, and session lookup asks on every authenticated request. The cache is
  off under test, where the sandbox rolls writes back without telling us.
  """
  def get(key) when is_atom(key) do
    if cache?() do
      case :persistent_term.get({__MODULE__, key}, :miss) do
        :miss ->
          value = load(key)
          :persistent_term.put({__MODULE__, key}, value)
          value

        cached ->
          cached
      end
    else
      load(key)
    end
  end

  defp load(key) do
    default = @defaults[key]

    case Repo.get_by(Setting, key: Atom.to_string(key)) do
      %{value: value} -> cast_value(value, default)
      nil -> default
    end
  end

  defp cache?, do: Application.get_env(:you, :settings_cache, true)

  @doc """
  Returns all setting keys with their current values.
  """
  def all do
    @defaults
    |> Enum.map(fn {key, _default} -> {key, get(key)} end)
    |> Map.new()
  end

  @doc """
  Sets a setting value. Upserts: creates if missing, updates if exists.
  Accepts both integers and strings.

  Raises `ArgumentError` for a key in `forbidden_keys/0` — bootstrap or key
  material has no console path, on purpose, so this cannot be bypassed by
  calling `set/2` directly.
  """
  def set(key, _value) when key in @forbidden_keys do
    raise ArgumentError,
          "#{key} is environment-only and cannot be set from the console"
  end

  def set(key, value) when is_atom(key) and is_boolean(value) do
    do_set(key, to_string(value))
  end

  def set(key, value) when is_atom(key) and is_integer(value) do
    do_set(key, Integer.to_string(value))
  end

  def set(key, value) when is_atom(key) and is_binary(value) do
    do_set(key, value)
  end

  defp do_set(key, value_str) do
    key_str = Atom.to_string(key)

    case Repo.get_by(Setting, key: key_str) do
      nil ->
        Repo.insert!(%Setting{key: key_str, value: value_str})

      existing ->
        existing |> Ecto.Changeset.change(value: value_str) |> Repo.update!()
    end

    invalidate(key)

    :ok
  end

  @doc """
  Refreshes this node's cached value for `key`, then tells the rest of the
  cluster to do the same.

  The local refresh is synchronous because the request that made the edit has
  to read its own write; every other node hears about it through `You.Cache`.
  """
  def invalidate(key) when is_atom(key) do
    refresh(key)
    You.Cache.broadcast({:setting, key})
    :ok
  end

  @doc """
  Refreshes this node's cached value for `key` from the database, without
  telling anyone else. `You.Cache` calls this on the receiving end of an
  invalidation broadcast.
  """
  def refresh(key) when is_atom(key) do
    if cache?(), do: :persistent_term.put({__MODULE__, key}, load(key))
    :ok
  end

  @doc """
  The analytics script to embed, as `[src: …, domain: …]`, or nil.

  Both halves are required: a script tag with no domain reports to the wrong
  site, so a half-configured pair counts as off.
  """
  def analytics do
    case {present(get(:analytics_src)), present(get(:analytics_domain))} do
      {src, domain} when is_binary(src) and is_binary(domain) -> [src: src, domain: domain]
      _ -> nil
    end
  end

  @doc """
  The management API bearer token, or nil when the API is disabled.

  Blank counts as unset, whitespace included: a token of spaces is a
  misconfiguration, and honouring it would be a credential nobody can see.
  """
  def api_token, do: get(:api_token) |> to_string() |> String.trim() |> present()

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value

  defp cast_value(value, default) when is_boolean(default), do: value == "true"
  defp cast_value(value, default) when is_integer(default), do: String.to_integer(value)
  defp cast_value(value, _default), do: value
end
