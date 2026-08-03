defmodule YouWeb.UserDashboardController do
  use YouWeb, :controller

  alias You.Accounts
  alias You.Admin

  @doc """
  The signed-in user's account hub: cards for every app the user has
  granted consent to, linking into the app (where they're already
  authenticated via You).

  In single-app mode there is nothing to choose between, so the hub is the
  account itself — profile, sessions, passkeys and 2FA.
  """
  def index(conn, _params) do
    if You.Mode.single?() do
      redirect(conn, to: ~p"/users/settings")
    else
      user = conn.assigns.current_scope.user
      render(conn, :index, apps: Accounts.list_consented_apps(user))
    end
  end

  @doc """
  Revokes the user's access to a given app (deletes their consent).
  """
  def revoke(conn, %{"app_id" => app_id}) do
    user = conn.assigns.current_scope.user

    {count, _} = Accounts.revoke_app_access(user, app_id)

    info =
      if count > 0 do
        app = Admin.get_app!(app_id)
        "Removed access to #{app.name}."
      else
        "App not found or access already removed."
      end

    conn
    |> put_flash(:info, info)
    |> redirect(to: ~p"/users/dashboard")
  end
end
