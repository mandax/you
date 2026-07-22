defmodule YouWeb.UserSettingsController do
  use YouWeb, :controller

  alias You.Repo
  alias You.Accounts
  alias You.Accounts.Consent
  alias You.Admin.App
  alias YouWeb.UserAuth

  import YouWeb.UserAuth, only: [require_sudo_mode: 2]

  plug :require_sudo_mode
  plug :assign_email_and_password_changesets

  def edit(conn, _params) do
    render(conn, :edit)
  end

  def revoke_session(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    info =
      case Accounts.delete_user_session(user, id) do
        1 -> "Session revoked."
        _ -> "Session not found."
      end

    conn |> put_flash(:info, info) |> redirect(to: ~p"/users/settings")
  end

  def revoke_other_sessions(conn, _params) do
    user = conn.assigns.current_scope.user
    count = Accounts.delete_other_user_sessions(user, get_session(conn, :user_token))

    conn
    |> put_flash(:info, "Signed out of #{count} other session(s).")
    |> redirect(to: ~p"/users/settings")
  end

  def access_data(conn, _params) do
    user = conn.assigns.current_scope.user

    apps =
      user.id
      |> get_user_consents()
      |> Enum.map(fn c ->
        %{
          name: c.app.name,
          scopes: c.scopes,
          granted_at: c.granted_at
        }
      end)

    data = %{
      email: user.email,
      confirmed_at: user.confirmed_at,
      totp_enabled: user.totp_enabled,
      created_at: user.inserted_at,
      updated_at: user.updated_at,
      apps: apps
    }

    json(conn, data)
  end

  def update(conn, %{"action" => "update_email"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_scope.user

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        conn
        |> put_flash(
          :info,
          "A link to confirm your email change has been sent to the new address."
        )
        |> redirect(to: ~p"/users/settings")

      changeset ->
        render(conn, :edit, email_changeset: %{changeset | action: :insert})
    end
  end

  def update(conn, %{"action" => "update_password"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_scope.user

    case Accounts.update_user_password(user, user_params) do
      {:ok, {user, _}} ->
        conn
        |> put_flash(:info, "Password updated successfully.")
        |> put_session(:user_return_to, ~p"/users/settings")
        |> UserAuth.log_in_user(user)

      {:error, changeset} ->
        render(conn, :edit, password_changeset: changeset)
    end
  end

  def confirm_email(conn, %{"token" => token}) do
    case Accounts.update_user_email(conn.assigns.current_scope.user, token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email changed successfully.")
        |> redirect(to: ~p"/users/settings")

      {:error, _} ->
        conn
        |> put_flash(:error, "Email change link is invalid or it has expired.")
        |> redirect(to: ~p"/users/settings")
    end
  end

  defp assign_email_and_password_changesets(conn, _opts) do
    user = conn.assigns.current_scope.user

    conn
    |> assign(:email_changeset, Accounts.change_user_email(user))
    |> assign(:password_changeset, Accounts.change_user_password(user))
    |> assign(:sessions, Accounts.list_user_sessions(user))
    |> assign(:current_token, get_session(conn, :user_token))
  end

  defp get_user_consents(user_id) do
    import Ecto.Query

    Repo.all(
      from c in Consent,
        join: a in App,
        on: c.app_id == a.id,
        where: c.user_id == ^user_id,
        select: %{app: a, scopes: c.scopes, granted_at: c.granted_at}
    )
  end
end
