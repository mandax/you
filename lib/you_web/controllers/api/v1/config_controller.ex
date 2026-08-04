defmodule YouWeb.API.V1.ConfigController do
  @moduledoc """
  Configuration bundles over HTTP, for CI promoting a staging configuration to
  production and for backup automation that does not depend on someone
  clicking a button in the console.

  Every action is a POST, including export: the bundle password would
  otherwise travel as a query string and land in access logs and browser
  history. `password` is in `config :phoenix, :filter_parameters`, so it is
  redacted from Phoenix's own logs.

  A sealed bundle is a JSON envelope, so it is carried as a string in the
  request and response body rather than as a file upload — `curl -d @file`
  and a CI step both work without multipart.
  """
  use YouWeb, :controller

  alias You.Config.Bundle
  alias You.Config.Vault

  @doc """
  POST /api/v1/config/bundle — seals this instance's configuration.

  Body: `{"password": "…"}`. Responds with the sealed envelope as
  `application/octet-stream`, the same bytes the console's download produces.
  """
  def export(conn, %{"password" => password}) when is_binary(password) do
    if String.length(password) < Vault.min_password_length() do
      error(conn, :unprocessable_entity, "password_too_short")
    else
      audit(conn, "export_config_bundle", "api")

      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_resp(200, Bundle.export() |> Vault.seal(password))
    end
  end

  def export(conn, _params), do: error(conn, :unprocessable_entity, "password_required")

  @doc """
  POST /api/v1/config/bundle/preview — reports what an import would change,
  without writing anything.

  Body: `{"password": "…", "bundle": "<envelope>"}`.
  """
  def preview(conn, params) do
    with {:ok, payload} <- open(params),
         {:ok, preview} <- Bundle.preview(payload) do
      json(conn, %{data: preview})
    else
      {:error, reason} -> bundle_error(conn, reason)
    end
  end

  @doc """
  POST /api/v1/config/bundle/import — applies a bundle to this instance.

  Body: `{"password": "…", "bundle": "<envelope>"}`. Upserts by natural key
  and never deletes; instance identity is refused in both directions.
  """
  def import(conn, params) do
    with {:ok, payload} <- open(params),
         {:ok, summary} <- Bundle.import(payload) do
      audit(conn, "import_config_bundle", summarize(summary))
      json(conn, %{data: summary})
    else
      {:error, reason} -> bundle_error(conn, reason)
    end
  end

  defp open(%{"password" => password, "bundle" => bundle})
       when is_binary(password) and is_binary(bundle) do
    Vault.open(bundle, password)
  end

  defp open(_params), do: {:error, :password_and_bundle_required}

  defp bundle_error(conn, :wrong_password), do: error(conn, :unauthorized, "wrong_password")

  defp bundle_error(conn, reason) when is_atom(reason),
    do: error(conn, :unprocessable_entity, Atom.to_string(reason))

  defp bundle_error(conn, reason),
    do: error(conn, :unprocessable_entity, inspect(reason))

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end

  defp summarize(summary), do: You.Config.CLI.describe_summary(summary)

  # The management API authenticates a bearer token, not a user, so there is
  # no admin id to record — but exporting a bundle is still the single most
  # privileged action this instance offers and has to leave a trace.
  defp audit(conn, action, target) do
    :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
      admin_user_id: nil,
      via: "api",
      remote_ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
      action: action,
      target: target
    })
  end
end
