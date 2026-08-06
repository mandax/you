defmodule YouWeb.ConsoleBackupController do
  @moduledoc """
  Downloads an encrypted configuration bundle.

  A plain controller action, not a LiveView event: LiveView has no way to
  stream a file to the browser as a download, and a bundle is sealed with a
  password that must never travel as a query string or land in a request log
  (see `config :phoenix, :filter_parameters` in `config/config.exs`). The
  console's Backup section posts here from a real HTML form, submitted via
  `phx-trigger-action` so the password field's value goes straight from the
  DOM to this action without passing through the LiveView socket.
  """
  use YouWeb, :controller

  alias You.Config.Bundle
  alias You.Config.Vault

  @doc """
  Seals `You.Config.Bundle.export/0` under the submitted password and sends it
  as a download named after this host and today's date.

  Emits the admin-audit event before responding: exporting a bundle removes
  every secret this instance holds in one file, which is the most privileged
  single action the console offers.
  """
  def export(conn, %{"password" => password}) when is_binary(password) do
    case validate_password(password) do
      :ok ->
        payload = Bundle.export() |> Vault.seal(password)
        filename = filename(conn)

        :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
          admin_user_id: conn.assigns.current_scope.user.id,
          action: "export_config_bundle",
          target: filename
        })

        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, payload)

      {:error, message} ->
        conn |> put_flash(:error, message) |> redirect(to: ~p"/console/backup")
    end
  end

  def export(conn, _params) do
    conn
    |> put_flash(:error, "A password is required to export a bundle.")
    |> redirect(to: ~p"/console/backup")
  end

  defp filename(conn), do: "#{conn.host}-#{Date.utc_today()}.you-bundle"

  defp validate_password(""), do: {:error, "A password is required to export a bundle."}

  defp validate_password(password) do
    if String.length(password) < Vault.min_password_length() do
      {:error, "The export password must be at least #{Vault.min_password_length()} characters."}
    else
      :ok
    end
  end
end
