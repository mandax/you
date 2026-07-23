defmodule YouWeb.UserDashboardController do
  use YouWeb, :controller

  @doc """
  The signed-in user's app launcher — cards for every registered app that
  send the user into the app (where they're already authenticated via You).
  """
  def index(conn, _params) do
    render(conn, :index, apps: You.Admin.list_apps())
  end
end
