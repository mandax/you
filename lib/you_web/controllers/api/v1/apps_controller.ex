defmodule YouWeb.API.V1.AppsController do
  use YouWeb, :controller

  alias You.Admin
  alias YouWeb.API.V1.JSON

  def index(conn, _params) do
    apps = Admin.list_apps()
    json(conn, %{data: Enum.map(apps, &JSON.app_json/1)})
  end

  def create(conn, params) do
    case Admin.create_app(params) do
      {:ok, app, client_secret} ->
        # The plaintext secret is returned exactly once, here — only its
        # SHA-256 hash is stored.
        conn
        |> put_status(201)
        |> json(%{data: Map.put(JSON.app_json(app), :client_secret, client_secret)})

      {:error, %Ecto.Changeset{} = changeset} ->
        unprocessable(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    case fetch_app(id) do
      nil ->
        not_found(conn)

      app ->
        case Admin.update_app(app, params) do
          {:ok, app} ->
            json(conn, %{data: JSON.app_json(app)})

          {:error, %Ecto.Changeset{} = changeset} ->
            unprocessable(conn, changeset)
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    case fetch_app(id) do
      nil ->
        not_found(conn)

      app ->
        {:ok, _app} = Admin.delete_app(app)
        send_resp(conn, 204, "")
    end
  end

  defp fetch_app(id) do
    Admin.get_app!(id)
  rescue
    Ecto.NoResultsError -> nil
    Ecto.Query.CastError -> nil
  end

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{error: "not_found"})
  end

  defp unprocessable(conn, changeset) do
    conn
    |> put_status(422)
    |> json(%{error: "validation_failed", details: JSON.changeset_errors(changeset)})
  end
end
