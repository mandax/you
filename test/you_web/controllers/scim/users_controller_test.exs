defmodule YouWeb.SCIM.UsersControllerTest do
  use YouWeb.ConnCase

  alias You.AccountsFixtures
  alias You.Accounts
  alias You.Repo
  alias You.Accounts.User

  @scim_user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @scim_list_schema "urn:ietf:params:scim:schemas:core:2.0:ListResponse"
  @token "test-scim-token"

  setup do
    previous = Application.get_env(:you, :scim_bearer_token)
    Application.put_env(:you, :scim_bearer_token, @token)

    on_exit(fn ->
      Application.put_env(:you, :scim_bearer_token, previous)
    end)

    :ok
  end

  defp with_bearer(conn), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{@token}")
  defp with_wrong_bearer(conn), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer wrong-token")

  describe "authentication" do
    test "rejects requests without bearer token", %{conn: conn} do
      conn = get(conn, "/scim/v2/Users")
      assert json_response(conn, 401)["status"] == "401"
    end

    test "rejects requests with wrong bearer token", %{conn: conn} do
      conn = conn |> with_wrong_bearer() |> get("/scim/v2/Users")
      assert json_response(conn, 401)["status"] == "401"
    end

    test "accepts requests with correct bearer token", %{conn: conn} do
      conn = conn |> with_bearer() |> get("/scim/v2/Users")
      assert json_response(conn, 200)["schemas"] == [@scim_list_schema]
    end
  end

  describe "POST /scim/v2/Users" do
    test "creates a user and returns 201 with Location header", %{conn: conn} do
      email = AccountsFixtures.unique_user_email()

      conn =
        with_bearer(conn)
        |> post("/scim/v2/Users", %{
          "schemas" => [@scim_user_schema],
          "userName" => email
        })

      assert conn.status == 201
      assert [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, "/scim/v2/Users/")

      body = json_response(conn, 201)
      assert body["schemas"] == [@scim_user_schema]
      assert body["userName"] == email
      assert body["active"] == true
      assert %{"value" => ^email, "primary" => true} = Enum.find(body["emails"], & &1["primary"])
      refute is_nil(body["id"])

      user = Repo.get!(User, body["id"])
      assert user.confirmed_at != nil
    end

    test "returns 400 when userName is missing", %{conn: conn} do
      conn =
        with_bearer(conn)
        |> post("/scim/v2/Users", %{"schemas" => [@scim_user_schema]})

      assert json_response(conn, 400)["status"] == "400"
    end
  end

  describe "GET /scim/v2/Users" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "lists all users as SCIM ListResponse", %{conn: conn} do
      conn = conn |> with_bearer() |> get("/scim/v2/Users")

      body = json_response(conn, 200)
      assert body["schemas"] == [@scim_list_schema]
      assert body["totalResults"] > 0
      assert is_list(body["Resources"])
      assert body["itemsPerPage"] == body["totalResults"]
    end

    test "filters by userName eq", %{conn: conn, user: user} do
      conn =
        with_bearer(conn)
        |> get("/scim/v2/Users?filter=userName+eq+\"#{user.email}\"")

      body = json_response(conn, 200)
      assert body["totalResults"] == 1
      assert [resource] = body["Resources"]
      assert resource["userName"] == user.email
    end

    test "filters by userName eq returns empty when no match", %{conn: conn} do
      conn =
        with_bearer(conn)
        |> get("/scim/v2/Users?filter=userName+eq+\"noone@example.com\"")

      body = json_response(conn, 200)
      assert body["totalResults"] == 0
      assert body["Resources"] == []
    end
  end

  describe "GET /scim/v2/Users/:id" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "returns a user by id", %{conn: conn, user: user} do
      conn = conn |> with_bearer() |> get("/scim/v2/Users/#{user.id}")

      body = json_response(conn, 200)
      assert body["schemas"] == [@scim_user_schema]
      assert body["id"] == user.id
      assert body["userName"] == user.email
    end

    test "returns 404 for unknown id", %{conn: conn} do
      conn =
        with_bearer(conn)
        |> get("/scim/v2/Users/999999")

      assert json_response(conn, 404)["status"] == "404"
    end
  end

  describe "PATCH /scim/v2/Users/:id" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "deactivates a user (active: false)", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)

      conn =
        with_bearer(conn)
        |> patch("/scim/v2/Users/#{user.id}", %{
          "schemas" => [@scim_user_schema],
          "active" => false
        })

      body = json_response(conn, 200)
      assert body["active"] == false

      user_db = Repo.get!(User, user.id)
      assert user_db.confirmed_at == nil

      refute Accounts.get_user_by_session_token(token)
    end

    test "activates a previously deactivated user", %{conn: conn, user: user} do
      {:ok, updated} =
        user
        |> Ecto.Changeset.change(confirmed_at: nil)
        |> Repo.update()

      refute updated.confirmed_at

      conn =
        with_bearer(conn)
        |> patch("/scim/v2/Users/#{user.id}", %{
          "schemas" => [@scim_user_schema],
          "active" => true
        })

      body = json_response(conn, 200)
      assert body["active"] == true

      user_db = Repo.get!(User, user.id)
      assert user_db.confirmed_at != nil
    end

    test "returns 404 for unknown id", %{conn: conn} do
      conn =
        with_bearer(conn)
        |> patch("/scim/v2/Users/999999", %{
          "schemas" => [@scim_user_schema],
          "active" => false
        })

      assert json_response(conn, 404)["status"] == "404"
    end
  end

  describe "DELETE /scim/v2/Users/:id" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "deactivates a user and returns 204", %{conn: conn, user: user} do
      conn = conn |> with_bearer() |> delete("/scim/v2/Users/#{user.id}")

      assert conn.status == 204

      user_db = Repo.get!(User, user.id)
      assert String.starts_with?(user_db.email, "redacted-")
    end

    test "returns 404 for unknown id", %{conn: conn} do
      conn =
        with_bearer(conn)
        |> delete("/scim/v2/Users/999999")

      assert json_response(conn, 404)["status"] == "404"
    end
  end

  describe "PUT /scim/v2/Users/:id" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "updates user email", %{conn: conn, user: user} do
      new_email = AccountsFixtures.unique_user_email()

      conn =
        with_bearer(conn)
        |> put("/scim/v2/Users/#{user.id}", %{
          "schemas" => [@scim_user_schema],
          "userName" => new_email,
          "active" => true
        })

      body = json_response(conn, 200)
      assert body["userName"] == new_email

      user_db = Repo.get!(User, user.id)
      assert user_db.email == new_email
    end

    test "returns 404 for unknown id", %{conn: conn} do
      conn =
        with_bearer(conn)
        |> put("/scim/v2/Users/999999", %{
          "schemas" => [@scim_user_schema],
          "userName" => "test@example.com"
        })

      assert json_response(conn, 404)["status"] == "404"
    end
  end
end
