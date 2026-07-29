defmodule YouWeb.SCIM.BearerAuth do
  @moduledoc """
  Authenticates SCIM requests via a configured bearer token.

  Configuration:

      config :you, :scim_bearer_token, "your-secret-token"

  When `:scim_bearer_token` is `nil` (the default), the plug returns 401
  for every request; SCIM is effectively disabled.

  The incoming `Authorization: Bearer <token>` header is compared in
  constant time to avoid timing side-channels.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    configured_token = configured_token()

    header = get_req_header(conn, "authorization") |> List.first()

    with true <- is_binary(configured_token) and configured_token != "",
         [_scheme, token] <- parse_header(header),
         true <- Plug.Crypto.secure_compare(token, configured_token) do
      conn
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            schemas: ["urn:ietf:params:scim:api:messages:2.0:Error"],
            status: "401",
            detail: "Unauthorized"
          })
        )
        |> halt()
    end
  end

  # Prefer the admin-managed DB setting; fall back to compile-time config so an
  # admin can still set it via `config :you, :scim_bearer_token, ...`.
  defp configured_token do
    case You.Settings.get(:scim_bearer_token) do
      token when is_binary(token) and token != "" -> token
      _ -> Application.get_env(:you, :scim_bearer_token)
    end
  end

  defp parse_header("Bearer " <> token), do: ["Bearer", String.trim(token)]
  defp parse_header("bearer " <> token), do: ["bearer", String.trim(token)]
  defp parse_header(_), do: :error
end
