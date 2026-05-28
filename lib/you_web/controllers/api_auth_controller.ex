defmodule YouWeb.ApiAuthController do
  use YouWeb, :controller

  alias You.JWT
  alias You.Accounts

  # 5 minutes
  @pre_auth_exp 300

  @doc """
  POST /api/login

  Returns JWT for valid credentials, or pre-auth token if 2FA is enabled.
  """
  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid email or password"})

      %{totp_enabled: true} = user ->
        {:ok, pre_auth_token} =
          JWT.sign(
            %{
              sub: user.id,
              email: user.email,
              purpose: "pre_auth"
            },
            @pre_auth_exp
          )

        json(conn, %{status: "2fa_required", pre_auth_token: pre_auth_token})

      user ->
        {:ok, jwt} =
          JWT.sign(%{
            sub: user.id,
            email: user.email,
            app: "you",
            role: "user"
          })

        json(conn, %{jwt: jwt})
    end
  end

  @doc """
  POST /api/login/verify

  Accepts a pre-auth token and TOTP code. Returns JWT on success.
  """
  def verify(conn, %{"pre_auth_token" => pre_auth_token, "totp_code" => totp_code}) do
    with {:ok, claims} <- JWT.verify(pre_auth_token),
         :ok <- verify_pre_auth(claims),
         {:ok, user} <- lookup_user(claims["sub"]),
         true <- Accounts.verify_totp(user, totp_code) do
      JWT.revoke(pre_auth_token)

      {:ok, jwt} =
        JWT.sign(%{
          sub: user.id,
          email: user.email,
          app: "you",
          role: "user"
        })

      json(conn, %{jwt: jwt})
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid verification"})
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

  defp verify_pre_auth(%{"purpose" => "pre_auth"}), do: :ok
  defp verify_pre_auth(_claims), do: {:error, :invalid_purpose}

  defp lookup_user(nil), do: {:error, :not_found}

  defp lookup_user(user_id) do
    case You.Repo.get(Accounts.User, user_id) do
      nil -> {:error, :not_found}
      %{id: _id} = user -> {:ok, user}
    end
  end
end
