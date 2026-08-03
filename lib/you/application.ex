defmodule You.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      YouWeb.Telemetry,
      You.Repo,
      You.IdentityProviders.Seeder,
      {DNSCluster, query: Application.get_env(:you, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: You.PubSub},
      You.Accounts.CookieSync,
      You.IAM.Server,
      You.Accounts.JtiCleanup,
      YouWeb.RateLimit,
      YouWeb.Endpoint
    ]

    children =
      if Application.get_env(:you, :audit, [])[:enabled] != false do
        [You.Audit.Handler | children]
      else
        children
      end

    # Seeds console-editable settings from the environment, then provisions
    # the single app. Both are no-ops after their first successful boot;
    # appended so they run after You.Repo is up, in this order so
    # You.Mode.single?/0 already reflects YOU_MODE by the time provisioning
    # decides whether to run.
    children = children ++ [You.Settings.EnvSeed, You.Mode.Provisioner]

    # Always include the Streamer; it is a no-op when unconfigured. Appended
    # (not prepended) because it reads the audit-webhook setting from the DB at
    # init, so it must start after You.Repo. Same for the webhook Dispatcher,
    # which queries endpoints from the DB per event.
    children = children ++ [You.Audit.Streamer, You.Webhooks.Dispatcher]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: You.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    YouWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
