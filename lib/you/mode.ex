defmodule You.Mode do
  @moduledoc """
  Deployment mode: `:multi` (the default, an identity provider for a fleet of
  apps) or `:single` (one app, configured from the environment).

  Single mode is a runtime flag, not a build variant. Same image, same schema,
  same tables — it only changes what gets provisioned on boot and what the
  console and the account hub render. Flipping `YOU_MODE` back to multi is a
  restart, never a migration.

  The single app is an ordinary row in `apps`: nothing downstream (JWT claims,
  role resolution, consent) knows which mode the instance runs in.
  """

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

  @doc "The slug of the single app, or nil in multi mode."
  def app_slug do
    case config() do
      nil -> nil
      config -> config[:slug]
    end
  end

  @doc """
  The single app row, or nil in multi mode (or before provisioning has run).

  Callers that render the console or the account hub use this; nothing in the
  auth path does, since the auth path resolves apps by callback URL either way.
  """
  def app do
    case app_slug() do
      nil -> nil
      slug -> Repo.get_by(App, slug: slug)
    end
  end
end
