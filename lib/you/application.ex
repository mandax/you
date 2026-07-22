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
      {DNSCluster, query: Application.get_env(:you, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: You.PubSub},
      You.Accounts.CookieSync,
      You.IAM.Server,
      You.Accounts.JtiCleanup,
      YouWeb.Endpoint
    ]

    children =
      if Application.get_env(:you, :audit, [])[:enabled] != false do
        [You.Audit.Handler | children]
      else
        children
      end

    # Always include the Streamer — it is a no-op when unconfigured. Appended
    # (not prepended) because it reads the audit-webhook setting from the DB at
    # init, so it must start after You.Repo.
    children = children ++ [You.Audit.Streamer]

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
