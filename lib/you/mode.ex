defmodule You.Mode do
  @moduledoc """
  Deployment mode: `:multi` (the default, an identity provider for a fleet of
  apps) or `:single` (one app, seeded from the environment on first boot).

  Single mode is a runtime flag, not a build variant: same image, same schema,
  same tables. Flipping it back to multi is a restart at most, never a
  migration, and the single app is an ordinary row in `apps` that nothing
  downstream — JWT claims, role resolution, consent — treats specially.

  The mode lives in the `you_mode` setting, which `YOU_MODE` seeds on first
  boot and the console owns thereafter. The environment-only half is
  `config :you, :single_app` — the slug, name and URLs used to provision that
  first app — which is seed data, not live configuration.
  """

  import Ecto.Query, only: [from: 2]

  alias You.Admin.App
  alias You.Repo

  @doc "The configured deployment mode."
  def mode do
    if You.Settings.get(:you_mode) == "single", do: :single, else: :multi
  end

  @doc "Whether this instance serves a single app."
  def single?, do: mode() == :single

  @doc "Environment-configured attributes of the single app, or nil in multi mode."
  def config do
    if single?(), do: Application.get_env(:you, :single_app), else: nil
  end

  @doc "The slug the environment seeded the single app with, or nil in multi mode."
  def app_slug do
    case config() do
      nil -> nil
      config -> config[:slug]
    end
  end

  @doc """
  The single app row, or nil in multi mode.

  Resolved by slug when that matches, otherwise by taking the registered app:
  the configured slug is only a seed, so it can drift once an admin renames
  the app in the console, and in single mode "the app" is a fact about the
  instance rather than about the environment.

  Cached in `:persistent_term`, since this is re-read on every branded page
  render — `YouWeb.AppBranding.panel_app/0` alone calls it from
  `Layouts.app/1` on every signed-in render, and it is near-immutable
  instance state in single mode. The cache is off under test, where the
  sandbox rolls writes back without telling us. Multi mode never caches or
  queries: `app/0` is `nil` there by definition.
  """
  def app do
    if single?() do
      if cache?() do
        case :persistent_term.get({__MODULE__, :app}, :miss) do
          :miss ->
            resolved = resolve_app()
            :persistent_term.put({__MODULE__, :app}, resolved)
            resolved

          cached ->
            cached
        end
      else
        resolve_app()
      end
    end
  end

  @doc """
  Invalidates the cached single app, forcing the next `app/0` to hit the
  database. Called by every writer of the `apps` table's single row:
  `You.Admin.create_app/1`, `update_app/2`, `rotate_app_secret/1`, and
  `delete_app/1`. A stale cache here shows a console name or logo that no
  longer exists, which matters more than the read it saves.
  """
  def invalidate_app_cache do
    :persistent_term.erase({__MODULE__, :app})
    :ok
  end

  defp resolve_app do
    case app_slug() && Repo.get_by(App, slug: app_slug()) do
      %App{} = app -> app
      _ -> Repo.one(from a in App, order_by: [asc: a.id], limit: 1)
    end
  end

  defp cache?, do: Application.get_env(:you, :mode_app_cache, true)
end
