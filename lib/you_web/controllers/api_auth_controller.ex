defmodule YouWeb.ApiAuthController do
  use YouWeb, :controller

  alias You.JWT
  alias You.Accounts

  @doc """
  POST /api/login

  Accepts `{"email": "...", "password": "..."}` and returns `{"jwt": "..."}`.
  """
  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid email or password"})

      user ->
        claims = %{
          sub: user.id,
          email: user.email,
          app: "you",
          role: "user"
        }

        {:ok, jwt} = JWT.sign(claims)
        conn |> json(%{jwt: jwt})
    end
  end

  @doc """
  DELETE /api/logout

  Revokes the JWT from the Authorization header.
  """
  def logout(conn, _params) do
    with ["Bearer " <> jwt] <- get_req_header(conn, "authorization") do
      JWT.revoke(jwt)
      send_resp(conn, 204, "")
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "missing or invalid authorization header"})
    end
  end
end
