defmodule You.Mode do
  @moduledoc """
  Deployment mode: `:multi` (the default, an identity provider for a fleet of
  apps) or `:single` (one app, seeded from the environment on first boot).

  Single mode is a runtime flag, not a build variant: same image, same schema,
  same tables. Flipping `YOU_MODE` back to multi is a restart, never a
  migration, and the single app is an ordinary row in `apps` that nothing
  downstream — JWT claims, role resolution, consent — treats specially.
  """

  import Ecto.Query, only: [from: 2]

  alias You.Admin.App
  alias You.Repo

  @doc "The configured deployment mode."
  def mode, do: Application.get_env(:you, :mode, :multi)

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
  """
  def app do
    if single?() do
      case app_slug() && Repo.get_by(App, slug: app_slug()) do
        %App{} = app -> app
        _ -> Repo.one(from a in App, order_by: [asc: a.id], limit: 1)
      end
    end
  end
end
