defmodule You.IdentityProviders.Seeder do
  @moduledoc """
  Seeds `identity_providers` from `config :you, :oidc_providers` once at boot.

  Migration path for existing deploys that still configure providers via app
  env: `seed_from_config/0` copies any provider not already in the table into
  it, so nothing is lost when the config key goes away.

  Runs in `handle_continue`, after `init/1` returns, so it executes once
  `You.Repo` is up in the supervision tree. A DB hiccup at boot must not
  crash the supervision tree — same precedent as `You.Audit.Streamer`. The
  process exits normally once the seed attempt completes; it has nothing
  left to do afterward.
  """

  use GenServer, restart: :transient
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :seed}}
  end

  @impl true
  def handle_continue(:seed, state) do
    try do
      You.IdentityProviders.seed_from_config()
    rescue
      error ->
        Logger.warning("[IdentityProviders.Seeder] seeding failed: #{inspect(error)}")
    end

    {:stop, :normal, state}
  end
end
