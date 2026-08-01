defmodule You.Mode.Provisioner do
  @moduledoc """
  Provisions the single app on first boot, so a fresh `docker compose up` lands
  on a working login instead of an empty registry.

  The environment **seeds** the app; it does not own it. Once the row exists
  the console is the source of truth and nothing here touches it again — an
  operator who changes their callback URL in the console keeps that change
  across restarts. Reconciling from the environment instead would mean every
  field on the console's app form silently reverting on the next
  `docker compose up`, which is a worse failure than the drift it prevents.

  Nothing is required to boot. An install with no `SINGLE_APP_CALLBACK_URL`
  still comes up with a working login page pointed at this instance's own
  account area, and the operator repoints it in the console once their app has
  a callback route.

  Declarative redeploys are the job of config-as-code (#60), not of this.
  """

  use Task, restart: :transient

  require Logger

  alias You.Admin
  alias You.Mode

  def start_link(_arg), do: Task.start_link(__MODULE__, :run, [])

  @doc """
  Provisions the app, and never raises.

  This runs inside the supervision tree, so an exception here is not a failed
  provision — it is a restart loop that exhausts the supervisor's budget and
  takes the whole node down, on a container that then cannot be exec'd into to
  fix it. An instance that boots without its app is diagnosable; one that
  crash-loops is not.
  """
  def run do
    if Mode.single?(), do: provision(Mode.config())
    :ok
  rescue
    error ->
      log_failure(Exception.message(error))
  catch
    # A checkout timeout against a busy pool exits rather than raising, and the
    # point of this clause is that nothing here takes the node down.
    :exit, reason ->
      log_failure(inspect(reason))
  end

  defp log_failure(detail) do
    Logger.error(
      "single-app mode: provisioning failed — #{detail}. " <>
        "The instance is up; register the app from the console, or fix the " <>
        "configuration and restart."
    )

    :ok
  end

  defp provision(nil), do: :ok

  defp provision(config) do
    case config[:slug] do
      slug when is_binary(slug) ->
        # Present already? Then the console owns it. Say nothing and touch
        # nothing — this is the path every restart after the first takes.
        if is_nil(You.Repo.get_by(You.Admin.App, slug: slug)), do: create(attrs(config))

      _ ->
        Logger.error("YOU_MODE=single requires SINGLE_APP_SLUG — no app provisioned")
    end
  end

  defp attrs(config) do
    %{
      "slug" => config[:slug],
      "name" => config[:name] || config[:slug],
      "callback_url" => config[:callback_url] || default_callback_url(),
      "launch_url" => config[:launch_url],
      # The single app is the instance: the user signing in is not authorizing
      # a third party, which is also what lets the headless API serve it.
      "first_party" => true
    }
  end

  # A placeholder that completes the round trip against this instance, so the
  # login flow can be walked end to end before the operator's app has a
  # callback route to point at. They replace it in the console.
  defp default_callback_url, do: YouWeb.Endpoint.url() <> "/users/settings"

  defp create(attrs) do
    case Admin.create_app(attrs) do
      {:ok, app, secret} ->
        persist_secret(secret)
        Logger.info("single-app mode: provisioned #{app.slug} (#{app.callback_url})")

      {:error, changeset} ->
        Logger.error("single-app mode: could not provision app — #{inspect(changeset.errors)}")
    end
  end

  defp persist_secret(secret) do
    path = Path.join(secret_dir(), "single_app_client_secret")

    # Narrow the mode before the secret goes in, not after: the data directory
    # is world-writable in the image, and a write-then-chmod leaves the
    # credential readable in between. Same order as the generated secrets in
    # config/runtime.exs.
    File.touch(path)
    File.chmod(path, 0o600)

    case File.write(path, secret <> "\n") do
      :ok ->
        Logger.info("single-app mode: client secret written to #{path}")

      {:error, reason} ->
        # Losing it is recoverable (rotate from the console), so this warns
        # rather than taking the boot down.
        Logger.warning(
          "single-app mode: could not write the client secret to #{path} (#{:file.format_error(reason)}). " <>
            "Rotate it from the console to obtain a new one."
        )
    end
  end

  defp secret_dir do
    Application.get_env(:you, You.Repo)[:database]
    |> case do
      path when is_binary(path) -> Path.dirname(path)
      _ -> System.tmp_dir!()
    end
  end
end
