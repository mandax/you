defmodule YouWeb.Plugs.ManagementAuth do
  @moduledoc """
  Authenticates management API requests via a configured bearer token.

  Configuration:

      config :you, :api_token, "your-secret-token"

  In production the token comes from the `API_TOKEN` environment variable
  (see `config/runtime.exs`). When it is unset or empty the management API
  is disabled and every request is halted with 403.

  The incoming `Authorization: Bearer <token>` header is compared in
  constant time to avoid timing side-channels.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Application.get_env(:you, :api_token) do
      token when is_binary(token) and token != "" ->
        check_token(conn, token)

      _ ->
        reject(conn, 403, "management_api_disabled")
    end
  end

  defp check_token(conn, configured_token) do
    with [token] <- bearer_token(conn),
         true <- secure_compare(token, configured_token) do
      conn
    else
      _ -> reject(conn, 401, "invalid_token")
    end
  end

  defp bearer_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         ["Bearer", token] <- String.split(header, " ", parts: 2) do
      [String.trim(token)]
    else
      _ -> []
    end
  end

  # secure_compare/2 raises on length mismatch, which would leak the
  # configured token length as a 500, so compare lengths first.
  defp secure_compare(token, configured_token) do
    byte_size(token) == byte_size(configured_token) and
      Plug.Crypto.secure_compare(token, configured_token)
  end

  defp reject(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
