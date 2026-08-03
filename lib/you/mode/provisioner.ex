defmodule You.Mode.Provisioner do
  @moduledoc """
  Seeds the single app on first boot, so a fresh `docker compose up` lands on a
  working login instead of an empty registry.

  The environment seeds; it does not own. Once an app exists the console is the
  source of truth and nothing here touches it again, so an operator's edits
  survive restarts. The check is "is any app registered", not "is this slug
  registered": keying on the slug would let a changed `SINGLE_APP_SLUG`
  provision a second app sharing the first one's callback URL, which makes
  `You.Admin.lookup_app_by_callback/1` raise on every interactive login.

  Nothing is required to boot. With no callback URL configured the app points
  back at this instance until it is repointed from the console. Declarative
  redeploys are the job of config-as-code (#60).
  """

  use Task, restart: :transient

  require Logger

  alias You.Admin
  alias You.Mode

  def start_link(_arg), do: Task.start_link(__MODULE__, :run, [])

  @doc """
  Provisions the app, and never raises.

  This runs inside the supervision tree, where an exception is not a failed
  provision but a restart loop that takes the node down — on a container that
  then cannot be exec'd into to fix it. An instance that boots without its app
  is diagnosable; one that crash-loops is not.
  """
  def run do
    if Mode.single?(), do: provision(Mode.config())
    :ok
  rescue
    error -> log_failure(Exception.message(error))
  catch
    :exit, reason -> log_failure(inspect(reason))
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
    case You.Repo.all(You.Admin.App) do
      [] ->
        create(attrs(config))

      [%{slug: slug}] ->
        warn_on_slug_drift(config[:slug], slug)

      _many ->
        Logger.warning(
          "single-app mode: #{You.Repo.aggregate(You.Admin.App, :count)} apps are registered. " <>
            "Nothing was provisioned; the console shows only the configured one."
        )
    end
  end

  defp warn_on_slug_drift(configured, _actual) when configured in [nil, ""], do: :ok
  defp warn_on_slug_drift(same, same), do: :ok

  defp warn_on_slug_drift(configured, actual) do
    Logger.warning(
      "single-app mode: SINGLE_APP_SLUG is #{inspect(configured)} but the registered app is " <>
        "#{inspect(actual)}. The app was not renamed — the console owns it after first boot. " <>
        "Rename it there, or set SINGLE_APP_SLUG back to #{inspect(actual)}."
    )
  end

  defp attrs(config) do
    %{
      "slug" => config[:slug],
      "name" => config[:name] || config[:slug],
      "callback_url" => config[:callback_url] || default_callback_url(),
      "launch_url" => config[:launch_url],
      "first_party" => true
    }
  end

  @doc """
  Placeholder callback that completes the round trip against this instance, so
  the login flow can be walked before the operator's app has a callback route.
  """
  def default_callback_url, do: YouWeb.Endpoint.url() <> "/users/settings"

  defp create(attrs) do
    case Admin.create_app(attrs) do
      {:ok, app, secret} ->
        persist_secret(secret)
        Logger.info("single-app mode: provisioned #{app.slug} (#{app.callback_url})")

      {:error, changeset} ->
        Logger.error("single-app mode: could not provision app — #{inspect(changeset.errors)}")
    end
  end

  # Created empty and narrowed to 0600 before the secret goes in: the data
  # directory is world-writable in the image.
  defp persist_secret(secret) do
    path = Path.join(secret_dir(), "single_app_client_secret")

    File.touch(path)
    File.chmod(path, 0o600)

    case File.write(path, secret <> "\n") do
      :ok ->
        Logger.info("single-app mode: client secret written to #{path}")

      {:error, reason} ->
        Logger.warning(
          "single-app mode: could not write the client secret to #{path} (#{:file.format_error(reason)}). " <>
            "Rotate it from the console to obtain a new one."
        )
    end
  end

  defp secret_dir do
    case Application.get_env(:you, You.Repo)[:database] do
      path when is_binary(path) -> Path.dirname(path)
      _ -> System.tmp_dir!()
    end
  end
end
