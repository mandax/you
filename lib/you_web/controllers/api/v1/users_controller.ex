defmodule YouWeb.API.V1.UsersController do
  use YouWeb, :controller

  alias You.Accounts
  alias You.Admin
  alias YouWeb.API.V1.JSON

  def index(conn, _params) do
    users = Admin.list_users()
    json(conn, %{data: Enum.map(users, &JSON.user_json/1)})
  end

  def show(conn, %{"id" => id}) do
    case fetch_user(id) do
      nil -> not_found(conn)
      user -> json(conn, %{data: JSON.user_json(user)})
    end
  end

  def create(conn, params) do
    case Accounts.register_user_with_password(params) do
      {:ok, user} ->
        conn
        |> put_status(201)
        |> json(%{data: JSON.user_json(user)})

      {:error, %Ecto.Changeset{} = changeset} ->
        unprocessable(conn, changeset)
    end
  end

  def logout(conn, %{"id" => id}) do
    case fetch_user(id) do
      nil ->
        not_found(conn)

      user ->
        :ok = Accounts.delete_all_user_tokens(user)
        json(conn, %{data: JSON.user_json(user)})
    end
  end

  def delete(conn, %{"id" => id}) do
    case fetch_user(id) do
      nil ->
        not_found(conn)

      user ->
        # LGPD: anonymize, never hard-delete.
        {:ok, user} = Accounts.anonymize_user(user)
        json(conn, %{data: JSON.user_json(user)})
    end
  end

  defp fetch_user(id) do
    Admin.get_user!(id)
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
