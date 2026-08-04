defmodule You.Config.Bundle do
  @moduledoc """
  Exports and imports an instance's configuration: settings, apps, identity
  providers, webhook endpoints and email templates.

  Configuration, not data — users, tokens, consents, sessions and per-user role
  assignments are deliberately absent. A bundle answers "make another instance
  behave like this one", which is staging/production parity and disaster
  recovery; it is not a database backup.

  Upstream provider secrets are stored encrypted under the *source* instance's
  `secret_key_base`, which the destination does not have, so they are decrypted
  on export and re-encrypted under the bundle password by `You.Config.Vault`.
  That is what lets a bundle be imported anywhere.

  Import upserts by natural key — settings by key, apps by slug, providers by
  slug, webhooks by url, email templates by key — and never deletes. An instance that has diverged
  keeps whatever the bundle does not mention.
  """

  alias You.Admin.App
  alias You.IdentityProviders.IdentityProvider
  alias You.Repo
  alias You.Settings
  alias You.Webhooks.Endpoint

  import Ecto.Query

  @version 1

  @app_fields ~w(slug name callback_url launch_url logo_url brand_color brand_color_dark
                 accent_color accent_color_dark theme_mode headline subtitle tos_url
                 privacy_url email_from_name enabled_providers enabled_methods
                 allowed_roles default_role first_party jwt_expiry_hours
                 code_expiry_minutes custom_claims)a

  @provider_fields ~w(slug display_name kind client_id issuer authorize_url token_url
                      userinfo_url scopes icon enabled sort_order)a

  @endpoint_fields ~w(url events enabled secret)a

  @email_template_fields ~w(key subject body)a

  @forbidden_setting_keys Enum.map(Settings.forbidden_keys(), &Atom.to_string/1)

  @instance_identity_keys ~w(erlang_cookie api_token scim_bearer_token)

  @doc """
  Settings a bundle can never carry, in either direction.

  Distinct from `You.Settings.forbidden_keys/0`, which is about console
  editability of environment-only bootstrap values. These three are
  console-editable, but they are *this instance's own identity* rather than
  configuration a bundle is meant to replicate: `erlang_cookie` gates
  distribution access, `api_token` and `scim_bearer_token` are bearer
  credentials for the management and SCIM APIs. A bundle exists to make
  *another* instance behave like this one — those values must be freshly
  minted there, never cloned in from a file that might have come from anyone.
  """
  def instance_identity_keys, do: @instance_identity_keys

  @secret_setting_keys ~w(erlang_cookie scim_bearer_token api_token smtp_password)

  @privileged_setting_keys ~w(api_token erlang_cookie scim_bearer_token audit_webhook_url
                              smtp_host smtp_port smtp_username smtp_password mail_from)

  @doc """
  Builds the bundle payload for this instance.
  """
  def export do
    %{
      "version" => @version,
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "settings" => export_settings(),
      "apps" => export_apps(),
      "identity_providers" => export_providers(),
      "webhook_endpoints" => export_endpoints(),
      "email_templates" => export_email_templates()
    }
  end

  @doc """
  Applies a bundle payload to this instance.

  Returns `{:ok, summary}` with a count per section, or `{:error, reason}` for
  a payload this version cannot read, or one whose shape or value types this
  instance cannot safely apply.

  Applied in one transaction, so a bundle that fails partway leaves the
  instance as it was. Processes that cache configuration are told to reload
  after the commit, not during it: they query on their own connection, which
  the open write transaction would block.
  """
  def import(%{"version" => version} = payload) when version <= @version do
    with :ok <- validate_payload(payload) do
      result =
        Repo.transaction(fn ->
          %{
            settings: apply_settings(payload["settings"] || %{}),
            apps: apply_apps(payload["apps"] || []),
            identity_providers: apply_providers(payload["identity_providers"] || []),
            webhook_endpoints: apply_endpoints(payload["webhook_endpoints"] || []),
            email_templates: apply_email_templates(payload["email_templates"] || [])
          }
        end)

      with {:ok, _summary} <- result, do: You.Webhooks.Dispatcher.reload()

      result
    end
  end

  def import(%{"version" => _}), do: {:error, :unsupported_version}
  def import(_payload), do: {:error, :malformed}

  @doc """
  Reports what `import/1` would actually change, computed against current
  state, without writing anything.

  Counting sections tells an operator nothing a hostile bundle can't fake —
  the point is to surface *values*: which settings differ (old → new, with
  secrets masked rather than hidden), which apps and identity providers are
  created or updated and where they point, and which instance-identity keys
  were present in the bundle and will be ignored.
  """
  def preview(%{"version" => version} = payload) when version <= @version do
    with :ok <- validate_payload(payload) do
      settings = payload["settings"] || %{}
      apps = payload["apps"] || []
      providers = payload["identity_providers"] || []
      endpoints = payload["webhook_endpoints"] || []

      settings_diff = diff_settings(settings)
      apps_diff = Enum.map(apps, &app_diff/1)
      providers_diff = Enum.map(providers, &provider_diff/1)
      endpoints_diff = Enum.map(endpoints, &endpoint_diff/1)
      ignored_settings = ignored_identity_settings(settings)

      {:ok,
       %{
         settings: settings_diff,
         ignored_settings: ignored_settings,
         apps: apps_diff,
         identity_providers: providers_diff,
         webhook_endpoints: endpoints_diff,
         privileged?:
           ignored_settings != [] or
             Enum.any?(settings_diff, &(&1.privileged? and &1.status != :unchanged)) or
             Enum.any?(apps_diff, &(&1.privileged? and &1.action != :unchanged)) or
             Enum.any?(providers_diff, &(&1.privileged? and &1.action != :unchanged))
       }}
    end
  end

  def preview(%{"version" => _}), do: {:error, :unsupported_version}
  def preview(_payload), do: {:error, :malformed}

  defp export_settings do
    Settings.all()
    |> Enum.reject(fn {key, _value} -> Atom.to_string(key) in @instance_identity_keys end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp export_apps do
    Repo.all(from a in App, order_by: a.slug)
    |> Enum.map(&(&1 |> Map.take(@app_fields) |> stringify()))
  end

  defp export_providers do
    Repo.all(from p in IdentityProvider, order_by: p.slug)
    |> Enum.map(fn provider ->
      provider
      |> Map.take(@provider_fields)
      |> stringify()
      |> Map.put("client_secret", decrypted_secret(provider))
    end)
  end

  defp export_endpoints do
    Repo.all(from e in Endpoint, order_by: e.url)
    |> Enum.map(&(&1 |> Map.take(@endpoint_fields) |> stringify()))
  end

  # Only the overrides: a template at its default has no row, and shipping a
  # copy of the default would freeze today's wording on the destination.
  defp export_email_templates do
    Repo.all(from t in You.EmailTemplates.EmailTemplate, order_by: t.key)
    |> Enum.map(&(&1 |> Map.take(@email_template_fields) |> stringify()))
  end

  defp apply_email_templates(templates) do
    Enum.count(templates, fn attrs ->
      match?({:ok, _}, You.EmailTemplates.upsert(attrs["key"] || "", attrs))
    end)
  end

  defp decrypted_secret(%IdentityProvider{client_secret: nil}), do: nil

  defp decrypted_secret(%IdentityProvider{client_secret: encrypted}) do
    case You.IdentityProviders.Crypto.fetch(encrypted) do
      {:ok, plaintext} -> plaintext
      :error -> nil
    end
  end

  # Skipping `Settings.forbidden_keys/0` and `@instance_identity_keys`
  # explicitly, rather than relying on those keys being absent from
  # `Settings.all/0` or from a well-behaved bundle, keeps this safe even on
  # the day one of those names is added to `@defaults` for an unrelated
  # reason, or a bundle carries one anyway — otherwise it would raise
  # `ArgumentError` inside the import transaction, and the failure would look
  # like a corrupt bundle rather than a code change.
  defp apply_settings(settings) do
    Enum.count(settings, fn {key, value} ->
      case cast_setting_key(key) do
        nil -> false
        atom -> Settings.set(atom, value) == :ok
      end
    end)
  end

  defp cast_setting_key(key) when key in @forbidden_setting_keys, do: nil
  defp cast_setting_key(key) when key in @instance_identity_keys, do: nil

  defp cast_setting_key(key) do
    known = Settings.all() |> Map.keys() |> Map.new(&{Atom.to_string(&1), &1})
    known[key]
  end

  defp apply_apps(apps) do
    Enum.count(apps, fn attrs ->
      case Repo.get_by(App, slug: attrs["slug"]) do
        nil -> match?({:ok, _, _}, You.Admin.create_app(attrs))
        app -> match?({:ok, _}, You.Admin.update_app(app, attrs))
      end
    end)
  end

  defp apply_providers(providers) do
    Enum.count(providers, fn attrs ->
      case Repo.get_by(IdentityProvider, slug: attrs["slug"]) do
        nil -> match?({:ok, _}, You.IdentityProviders.create_provider(attrs))
        provider -> match?({:ok, _}, You.IdentityProviders.update_provider(provider, attrs))
      end
    end)
  end

  # Writes rows directly rather than through `You.Webhooks`, whose every
  # mutator reloads the dispatcher mid-transaction. `import/1` reloads once
  # after the commit instead.
  defp apply_endpoints(endpoints) do
    Enum.count(endpoints, fn attrs ->
      changeset =
        case Repo.get_by(Endpoint, url: attrs["url"]) do
          nil -> Endpoint.changeset(%Endpoint{}, attrs)
          endpoint -> Endpoint.changeset(endpoint, attrs)
        end

      match?({:ok, _}, Repo.insert_or_update(changeset))
    end)
  end

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp ignored_identity_settings(settings) do
    settings
    |> Enum.filter(fn {key, _value} -> key in @instance_identity_keys end)
    |> Enum.map(fn {key, _value} -> key end)
    |> Enum.sort()
  end

  defp diff_settings(settings) do
    current = Settings.all()

    settings
    |> Enum.reject(fn {key, _value} -> key in @instance_identity_keys end)
    |> Enum.filter(fn {key, _value} -> cast_setting_key(key) != nil end)
    |> Enum.map(fn {key, value} ->
      atom = cast_setting_key(key)
      old = Map.get(current, atom)
      secret? = key in @secret_setting_keys
      status = setting_status(old, value)

      %{
        key: key,
        secret?: secret?,
        privileged?: key in @privileged_setting_keys,
        status: status,
        old: if(secret?, do: nil, else: old),
        new: if(secret?, do: nil, else: value)
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp setting_status(old, new) do
    old_str = to_string(old)
    new_str = to_string(new)

    cond do
      old_str == new_str -> :unchanged
      new_str == "" -> :cleared
      old_str == "" -> :set
      true -> :changed
    end
  end

  defp app_diff(attrs) do
    first_party? = truthy?(Map.get(attrs, "first_party", false))

    case Repo.get_by(App, slug: attrs["slug"]) do
      nil ->
        %{
          action: :create,
          slug: attrs["slug"],
          callback_url: attrs["callback_url"],
          first_party: first_party?,
          privileged?: first_party?
        }

      app ->
        changed? = fields_changed?(attrs, app, @app_fields)
        first_party? = truthy?(Map.get(attrs, "first_party", app.first_party))

        %{
          action: if(changed?, do: :update, else: :unchanged),
          slug: attrs["slug"],
          callback_url: Map.get(attrs, "callback_url", app.callback_url),
          first_party: first_party?,
          privileged?: first_party?
        }
    end
  end

  defp provider_diff(attrs) do
    case Repo.get_by(IdentityProvider, slug: attrs["slug"]) do
      nil ->
        enabled? = truthy?(Map.get(attrs, "enabled", true))

        %{
          action: :create,
          slug: attrs["slug"],
          authorize_url: attrs["authorize_url"],
          token_url: attrs["token_url"],
          userinfo_url: attrs["userinfo_url"],
          enabled: enabled?,
          privileged?: enabled?
        }

      provider ->
        secret_changed? = provider_secret_changed?(attrs, provider)

        changed? =
          fields_changed?(attrs, provider, @provider_fields -- [:slug]) or secret_changed?

        enabled? = truthy?(Map.get(attrs, "enabled", provider.enabled))

        %{
          action: if(changed?, do: :update, else: :unchanged),
          slug: attrs["slug"],
          authorize_url: Map.get(attrs, "authorize_url", provider.authorize_url),
          token_url: Map.get(attrs, "token_url", provider.token_url),
          userinfo_url: Map.get(attrs, "userinfo_url", provider.userinfo_url),
          enabled: enabled?,
          privileged?: enabled?
        }
    end
  end

  defp endpoint_diff(attrs) do
    case Repo.get_by(Endpoint, url: attrs["url"]) do
      nil ->
        %{action: :create, url: attrs["url"]}

      endpoint ->
        secret_changed? = present?(attrs["secret"]) and attrs["secret"] != endpoint.secret

        changed? =
          fields_changed?(attrs, endpoint, @endpoint_fields -- [:secret]) or secret_changed?

        %{action: if(changed?, do: :update, else: :unchanged), url: attrs["url"]}
    end
  end

  defp fields_changed?(attrs, struct, fields) do
    Enum.any?(fields, fn field ->
      case Map.fetch(attrs, Atom.to_string(field)) do
        {:ok, value} -> normalize(value) != normalize(Map.get(struct, field))
        :error -> false
      end
    end)
  end

  defp normalize(value) when is_list(value), do: Enum.sort(value)
  defp normalize(value), do: value

  defp provider_secret_changed?(attrs, provider) do
    present?(attrs["client_secret"]) and
      case decrypted_secret(provider) do
        nil -> true
        current -> attrs["client_secret"] != current
      end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false

  defp validate_payload(payload) do
    with :ok <- validate_settings_shape(payload["settings"]),
         :ok <- validate_list_shape(payload["apps"]),
         :ok <- validate_list_shape(payload["identity_providers"]),
         :ok <- validate_list_shape(payload["webhook_endpoints"]),
         :ok <- validate_list_shape(payload["email_templates"]) do
      :ok
    end
  end

  defp validate_settings_shape(nil), do: :ok

  defp validate_settings_shape(settings) when is_map(settings) do
    current = Settings.all()

    if Enum.all?(settings, fn {key, value} -> valid_setting_value?(key, value, current) end) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp validate_settings_shape(_settings), do: {:error, :malformed}

  defp valid_setting_value?(key, value, current) do
    case cast_setting_key(key) do
      nil -> true
      atom -> castable?(value, Map.get(current, atom))
    end
  end

  defp castable?(value, _current) when is_float(value), do: false

  defp castable?(value, _current)
       when not (is_binary(value) or is_integer(value) or is_boolean(value)),
       do: false

  defp castable?(value, current) when is_integer(current) and is_binary(value) do
    match?({_int, ""}, Integer.parse(value))
  end

  defp castable?(_value, _current), do: true

  defp validate_list_shape(nil), do: :ok

  defp validate_list_shape(list) when is_list(list) do
    if Enum.all?(list, &is_map/1), do: :ok, else: {:error, :malformed}
  end

  defp validate_list_shape(_list), do: {:error, :malformed}
end
