defmodule YouWeb.HeadlessAuthController do
  @moduledoc """
  Headless auth API for trusted first-party apps (the HTTP twin of
  `You.IAM.Server.password_login/3`, for non-BEAM consumers).

  The app authenticates the end user from its own UI and receives a token
  bundle directly: no redirect, no You-branded page. The app itself is
  authenticated by its `client_id` + `client_secret` (HTTP Basic, or in the
  body), and must be flagged `first_party`.
  """
  use YouWeb, :controller

  @doc """
  POST /api/auth/login

  Client auth: HTTP Basic (`client_id:client_secret`) or body `client_id` +
  `client_secret`. Body: `email`, `password`, optional `scope`
  (space-separated), optional `totp_code`.
  """
  def login(conn, params) do
    {client_id, client_secret} = client_auth(conn, params)

    case You.IAM.Server.password_login(client_id, client_secret, params) do
      {:ok, bundle} ->
        conn
        |> put_status(:ok)
        |> json(%{
          access_token: bundle.jwt,
          token_type: "Bearer",
          refresh_token: bundle.refresh_token,
          user: %{id: bundle.user_id, email: bundle.email}
        })

      {:error, reason} ->
        {status, body} = error_response(reason)

        conn
        |> put_status(status)
        |> json(body)
    end
  end

  @doc """
  POST /api/auth/register

  Same client-auth mechanism as `login/2`. Body: `email`, `password`,
  optional `scope` (space-separated).  Creates an unconfirmed user and
  returns a token bundle on success (HTTP 201).
  """
  def register(conn, params) do
    {client_id, client_secret} = client_auth(conn, params)

    case You.IAM.Server.register(client_id, client_secret, params) do
      {:ok, bundle} ->
        conn
        |> put_status(:created)
        |> json(%{
          access_token: bundle.jwt,
          token_type: "Bearer",
          refresh_token: bundle.refresh_token,
          user: %{id: bundle.user_id, email: bundle.email}
        })

      {:error, reason} ->
        {status, body} = error_response(reason)

        conn
        |> put_status(status)
        |> json(body)
    end
  end

  @doc """
  POST /api/auth/guest

  Same client-auth mechanism as `login/2`. No user credentials: creates an
  anonymous account and returns a token bundle whose JWT carries
  `guest: true`, so the app can hold state for someone before they sign up.

  `403 guests_disabled` unless the instance has switched guest accounts on.
  """
  def guest(conn, params) do
    {client_id, client_secret} = client_auth(conn, params)

    conn
    |> respond(You.IAM.Server.guest_login(client_id, client_secret, params), :created)
  end

  @doc """
  POST /api/auth/upgrade

  Turns a guest into a real account with `email` + `password`, keeping the
  same user id — which is the whole point: the app's own rows keep pointing at
  the right person.

  The guest's own access token is the credential, taken from the
  `Authorization: Bearer` header when client auth came in the body, or from
  the `access_token` parameter. Responds with a fresh bundle; the old token
  still says `guest: true` until it expires.
  """
  def upgrade(conn, params) do
    {client_id, client_secret} = client_auth(conn, params)

    case guest_token(conn, params) do
      nil ->
        conn |> put_status(:unauthorized) |> json(%{error: "invalid_token"})

      jwt ->
        respond(conn, You.IAM.Server.upgrade_guest(client_id, client_secret, jwt, params), :ok)
    end
  end

  # The bearer header carries the *guest's* token here, not client auth, which
  # for this endpoint is in the body. `access_token` covers a client that has
  # already spent the header on Basic client auth.
  defp guest_token(conn, params) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {_id, _secret} -> present(params["access_token"])
      :error -> bearer(conn) || present(params["access_token"])
    end
  end

  defp bearer(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         ["Bearer", token] <- String.split(header, " ", parts: 2) do
      present(String.trim(token))
    else
      _ -> nil
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp respond(conn, {:ok, bundle}, status) do
    conn
    |> put_status(status)
    |> json(%{
      access_token: bundle.jwt,
      token_type: "Bearer",
      refresh_token: bundle.refresh_token,
      user: %{id: bundle.user_id, email: bundle.email}
    })
  end

  defp respond(conn, {:error, reason}, _status) do
    {status, body} = error_response(reason)
    conn |> put_status(status) |> json(body)
  end

  # Prefer HTTP Basic client auth; fall back to body params. Always returns
  # binaries so the IAM guard clause matches (empty → invalid_client).
  defp client_auth(conn, params) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {id, secret} -> {id, secret}
      :error -> {to_string(params["client_id"] || ""), to_string(params["client_secret"] || "")}
    end
  end

  defp error_response(:email_taken),
    do: {:conflict, %{error: "email_taken"}}

  defp error_response(:invalid_registration),
    do: {:unprocessable_entity, %{error: "invalid_registration"}}

  defp error_response(:mfa_required),
    do: {:unauthorized, %{error: "mfa_required", error_description: "A TOTP code is required."}}

  defp error_response(:invalid_mfa),
    do: {:unauthorized, %{error: "invalid_mfa", error_description: "The TOTP code is invalid."}}

  defp error_response(:invalid_credentials),
    do: {:unauthorized, %{error: "invalid_credentials"}}

  defp error_response(:guests_disabled),
    do:
      {:forbidden,
       %{
         error: "guests_disabled",
         error_description: "This instance does not issue guest accounts."
       }}

  defp error_response(:not_a_guest),
    do:
      {:conflict,
       %{
         error: "not_a_guest",
         error_description: "That account has already been upgraded."
       }}

  defp error_response(:invalid_token),
    do: {:unauthorized, %{error: "invalid_token"}}

  defp error_response(:not_first_party),
    do:
      {:forbidden,
       %{
         error: "unauthorized_client",
         error_description: "This client may not use the headless password grant."
       }}

  defp error_response(_),
    do: {:unauthorized, %{error: "invalid_client"}}
end
