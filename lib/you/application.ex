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
      # Before anything that writes a cached setting: an invalidation
      # broadcast with no PubSub behind it reaches no other node.
      {Phoenix.PubSub, name: You.PubSub},
      You.Cache,
      # Seeds console-editable settings from the environment, then provisions
      # the single app. Both are no-ops after their first successful boot, and
      # both need You.Repo. They come before the endpoint because `you_mode`
      # is one of the settings they seed: starting them later would leave a
      # window where the first requests are served as multi mode.
      You.Settings.EnvSeed,
      You.Mode.Provisioner,
      You.IdentityProviders.Seeder,
      {DNSCluster, query: Application.get_env(:you, :dns_cluster_query) || :ignore},
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

    # Always include the Streamer; it is a no-op when unconfigured. Appended
    # (not prepended) because it reads the audit-webhook setting from the DB at
    # init, so it must start after You.Repo. Same for the webhook Dispatcher,
    # which queries endpoints from the DB per event.
    #
    # The Task.Supervisor comes before the Dispatcher because every delivery
    # runs under it. Supervising them (rather than bare `Task.start`) is what
    # makes an in-flight delivery findable, and so terminable, by something
    # other than itself — see `You.DataCase.setup_sandbox/1` (#159).
    # `rest_for_one` for the webhook pair: the Dispatcher's telemetry handler
    # calls into You.Webhooks.TaskSupervisor by name, so a supervisor that
    # restarted without the Dispatcher restarting too would leave the handler
    # pointing at a dead name. Under `rest_for_one` the Dispatcher is restarted
    # after it, which re-attaches the handler.
    webhooks = [
      {Task.Supervisor, name: You.Webhooks.TaskSupervisor},
      You.Webhooks.Dispatcher
    ]

    children =
      children ++
        [
          You.Audit.Streamer,
          %{
            id: You.Webhooks.Supervisor,
            type: :supervisor,
            start:
              {Supervisor, :start_link,
               [webhooks, [strategy: :rest_for_one, name: You.Webhooks.Supervisor]]}
          }
        ]

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
