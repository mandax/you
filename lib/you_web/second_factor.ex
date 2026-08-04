defmodule YouWeb.SecondFactor do
  @moduledoc """
  The second-factor gate every interactive first factor passes through.

  Two-factor authentication is a property of the account, not of the method
  used to prove the first factor: an account with TOTP or email 2FA enrolled
  must meet it whether the user arrived by password, by magic link, or through
  an identity provider. Only the password path used to check, so requesting a
  magic link — or signing in through any enabled provider — was enough to skip
  the second factor entirely.

  Passkeys do not pass through here. A passkey is already a possession factor
  with user verification; it is not a first factor awaiting a second one.
  """
  use YouWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias You.Accounts

  @doc """
  Finishes an interactive login for `user`.

  Redirects to the account's enrolled second factor when there is one, and
  otherwise flashes `info` and hands off to `YouWeb.OAuthFlow.complete_login/3`,
  which either mints an authorization code for the requesting app or signs the
  user into You.
  """
  def complete_login(conn, user, info, params \\ %{}) do
    case challenge(conn, user) do
      {:challenge, conn} ->
        conn

      :none ->
        conn
        |> put_flash(:info, info)
        |> YouWeb.OAuthFlow.complete_login(user, params)
    end
  end

  @doc """
  Returns `{:challenge, conn}` redirecting to the second factor the account is
  enrolled in, or `:none` when it has none.

  The pending user is stashed in the session rather than logged in, so the
  challenge pages have someone to verify without the browser holding a session
  that already counts as authenticated.
  """
  def challenge(conn, user)

  def challenge(conn, %{totp_enabled: true} = user) do
    {:challenge,
     conn
     |> put_session(:totp_user_id, user.id)
     |> redirect(to: ~p"/users/log-in/totp")}
  end

  def challenge(conn, %{email_2fa_enabled: true} = user) do
    Accounts.send_email_2fa_code(user)

    {:challenge,
     conn
     |> put_session(:email_2fa_user_id, user.id)
     |> redirect(to: ~p"/users/log-in/email-2fa")}
  end

  def challenge(_conn, _user), do: :none
end
