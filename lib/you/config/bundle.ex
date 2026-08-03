defmodule You.Config.Bundle do
  @moduledoc """
  Exports and imports an instance's configuration: settings, apps, identity
  providers and webhook endpoints.

  Configuration, not data — users, tokens, consents, sessions and per-user role
  assignments are deliberately absent. A bundle answers "make another instance
  behave like this one", which is staging/production parity and disaster
  recovery; it is not a database backup.

  Upstream provider secrets are stored encrypted under the *source* instance's
  `secret_key_base`, which the destination does not have, so they are decrypted
  on export and re-encrypted under the bundle password by `You.Config.Vault`.
  That is what lets a bundle be imported anywhere.

  Import upserts by natural key — settings by key, apps by slug, providers by
  slug, webhooks by url — and never deletes. An instance that has diverged
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
                 allowed_roles default_role first_party)a

  @provider_fields ~w(slug display_name kind client_id issuer authorize_url token_url
                      userinfo_url scopes icon enabled sort_order)a

  @endpoint_fields ~w(url events enabled secret)a

  @forbidden_setting_keys Enum.map(Settings.forbidden_keys(), &Atom.to_string/1)

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
      "webhook_endpoints" => export_endpoints()
    }
  end

  @doc """
  Applies a bundle payload to this instance.

  Returns `{:ok, summary}` with a count per section, or `{:error, reason}` for
  a payload this version cannot read.

  Applied in one transaction, so a bundle that fails partway leaves the
  instance as it was. Processes that cache configuration are told to reload
  after the commit, not during it: they query on their own connection, which
  the open write transaction would block.
  """
  def import(%{"version" => version} = payload) when version <= @version do
    result =
      Repo.transaction(fn ->
        %{
          settings: apply_settings(payload["settings"] || %{}),
          apps: apply_apps(payload["apps"] || []),
          identity_providers: apply_providers(payload["identity_providers"] || []),
          webhook_endpoints: apply_endpoints(payload["webhook_endpoints"] || [])
        }
      end)

    with {:ok, _summary} <- result, do: You.Webhooks.Dispatcher.reload()

    result
  end

  def import(%{"version" => _}), do: {:error, :unsupported_version}
  def import(_payload), do: {:error, :malformed}

  @doc """
  Counts what `import/1` would change per section, without writing anything.

  What the console shows an operator before `import/1` is called: the same
  version check, none of the writes.
  """
  def preview(%{"version" => version} = payload) when version <= @version do
    {:ok,
     %{
       settings: map_size(payload["settings"] || %{}),
       apps: length(payload["apps"] || []),
       identity_providers: length(payload["identity_providers"] || []),
       webhook_endpoints: length(payload["webhook_endpoints"] || [])
     }}
  end

  def preview(%{"version" => _}), do: {:error, :unsupported_version}
  def preview(_payload), do: {:error, :malformed}

  defp export_settings do
    Settings.all() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
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

  defp decrypted_secret(%IdentityProvider{client_secret: nil}), do: nil

  defp decrypted_secret(%IdentityProvider{client_secret: encrypted}) do
    case You.IdentityProviders.Crypto.fetch(encrypted) do
      {:ok, plaintext} -> plaintext
      :error -> nil
    end
  end

  # Skipping `Settings.forbidden_keys/0` explicitly, rather than relying on
  # those keys being absent from `Settings.all/0`, keeps this safe even on the
  # day one of those names is added to `@defaults` for an unrelated reason —
  # otherwise a bundle carrying it would raise `ArgumentError` inside the
  # import transaction, and the failure would look like a corrupt bundle
  # rather than a code change.
  defp apply_settings(settings) do
    Enum.count(settings, fn {key, value} ->
      case cast_setting_key(key) do
        nil -> false
        atom -> Settings.set(atom, value) == :ok
      end
    end)
  end

  defp cast_setting_key(key) when key in @forbidden_setting_keys, do: nil

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
end
