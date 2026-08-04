defmodule YouWeb.InvitationController do
  @moduledoc """
  Accepting an admin's invitation.

  `show/2` presents what is being accepted — which app, which role — rather
  than acting on a GET: a link preview fetched by a mail client must not spend
  a single-use invitation. `accept/2` is the POST that does.

  Acceptance proves control of the mailbox and is therefore treated exactly
  like a magic link: it confirms the account and signs the user in through
  `YouWeb.SecondFactor`, so an account with an authenticator enrolled still
  meets it. What the invitation adds is the role.
  """
  use YouWeb, :controller

  alias You.Invitations

  def show(conn, %{"token" => token}) do
    case Invitations.get_by_token(token) do
      nil -> reject(conn)
      invitation -> render(conn, :show, [invitation: invitation, token: token] ++ branding(conn))
    end
  end

  def accept(conn, %{"token" => token}) do
    with %{} = invitation <- Invitations.get_by_token(token),
         {:ok, user} <- Invitations.resolve_user(invitation),
         {:ok, ^user} <- Invitations.accept(invitation, user) do
      YouWeb.SecondFactor.complete_login(conn, user, welcome(invitation))
    else
      nil -> reject(conn)
      _error -> failed(conn)
    end
  end

  defp welcome(%{app: %{name: name}}), do: "Welcome to #{name}."
  defp welcome(_invitation), do: "Welcome!"

  defp branding(conn), do: YouWeb.AppBranding.assigns(conn)

  defp reject(conn) do
    conn
    |> put_flash(:error, "That invitation is invalid, expired, or already used.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp failed(conn) do
    conn
    |> put_flash(:error, "That invitation could not be accepted. Ask for a new one.")
    |> redirect(to: ~p"/users/log-in")
  end
end
