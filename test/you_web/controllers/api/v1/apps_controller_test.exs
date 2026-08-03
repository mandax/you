defmodule YouWeb.API.V1.AppsControllerTest do
  use YouWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:you, :api_token)
    Application.put_env(:you, :api_token, "test-api-token")
    on_exit(fn -> Application.put_env(:you, :api_token, previous) end)
    :ok
  end

  alias You.Admin

  setup %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer test-api-token")
    %{conn: conn}
  end

  defp app_fixture(attrs \\ %{}) do
    {:ok, app, secret} =
      Admin.create_app(
        Map.merge(
          %{
            slug: "app-#{System.unique_integer([:positive])}",
            name: "My App",
            callback_url: "https://app.example.com/cb"
          },
          attrs
        )
      )

    {app, secret}
  end

  describe "GET /api/v1/apps" do
    test "lists apps without the secret hash", %{conn: conn} do
      {app, _secret} = app_fixture()

      conn = get(conn, ~p"/api/v1/apps")
      assert %{"data" => apps} = json_response(conn, 200)

      assert %{
               "id" => id,
               "slug" => slug,
               "name" => name,
               "callback_url" => callback_url,
               "launch_url" => nil,
               "first_party" => false
             } = Enum.find(apps, &(&1["id"] == app.id))

      assert id == app.id
      assert slug == app.slug
      assert name == app.name
      assert callback_url == app.callback_url

      refute Enum.any?(apps, &Map.has_key?(&1, "client_secret_hash"))
      refute Enum.any?(apps, &Map.has_key?(&1, "client_secret"))
    end
  end

  describe "POST /api/v1/apps" do
    test "creates an app and returns the one-time client secret", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/apps", %{
          "slug" => "new-app",
          "name" => "New App",
          "callback_url" => "https://new.example.com/cb",
          "first_party" => true
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["slug"] == "new-app"
      assert data["first_party"] == true
      assert is_binary(data["client_secret"])
      refute Map.has_key?(data, "client_secret_hash")

      # The secret is only returned once — it never appears again.
      conn = get(conn, ~p"/api/v1/apps")
      assert %{"data" => [app | _]} = json_response(conn, 200)
      refute Map.has_key?(app, "client_secret")
      refute Map.has_key?(app, "client_secret_hash")
    end

    test "missing required fields is 422", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/apps", %{"slug" => "incomplete"})

      assert %{"error" => "validation_failed", "details" => details} =
               json_response(conn, 422)

      assert details["name"]
      assert details["callback_url"]
    end

    test "duplicate slug is 422", %{conn: conn} do
      {app, _secret} = app_fixture()

      conn =
        post(conn, ~p"/api/v1/apps", %{
          "slug" => app.slug,
          "name" => "Copycat",
          "callback_url" => "https://copy.example.com/cb"
        })

      assert %{"error" => "validation_failed", "details" => %{"slug" => [_ | _]}} =
               json_response(conn, 422)
    end
  end

  describe "PATCH /api/v1/apps/:id" do
    test "updates allowed fields", %{conn: conn} do
      {app, _secret} = app_fixture()

      conn =
        patch(conn, ~p"/api/v1/apps/#{app.id}", %{
          "name" => "Renamed",
          "launch_url" => "https://app.example.com/home",
          "first_party" => true
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["name"] == "Renamed"
      assert data["launch_url"] == "https://app.example.com/home"
      assert data["first_party"] == true
    end

    test "unknown id is 404", %{conn: conn} do
      conn = patch(conn, ~p"/api/v1/apps/0", %{"name" => "Nope"})
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "invalid update is 422", %{conn: conn} do
      {app, _secret} = app_fixture()

      conn = patch(conn, ~p"/api/v1/apps/#{app.id}", %{"name" => nil})

      assert %{"error" => "validation_failed", "details" => %{"name" => [_ | _]}} =
               json_response(conn, 422)
    end
  end

  describe "DELETE /api/v1/apps/:id" do
    test "deletes the app", %{conn: conn} do
      {app, _secret} = app_fixture()

      conn = delete(conn, ~p"/api/v1/apps/#{app.id}")
      assert response(conn, 204)

      assert_raise Ecto.NoResultsError, fn -> Admin.get_app!(app.id) end
    end

    test "unknown id is 404", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/apps/0")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "PUT /api/v1/apps/:id/roles/:user_id" do
    test "assigns a role", %{conn: conn} do
      {app, _secret} = app_fixture()
      user = You.AccountsFixtures.user_fixture()

      conn = put(conn, ~p"/api/v1/apps/#{app.id}/roles/#{user.id}", role: "admin")

      assert %{"data" => %{"user_id" => uid, "role" => "admin"}} = json_response(conn, 200)
      assert uid == user.id
      assert You.Roles.role_for(app.slug, user.id) == "admin"
    end

    test "rejects a role the app does not allow", %{conn: conn} do
      {app, _secret} = app_fixture(%{allowed_roles: ["user"]})
      user = You.AccountsFixtures.user_fixture()

      conn = put(conn, ~p"/api/v1/apps/#{app.id}/roles/#{user.id}", role: "admin")

      assert %{"error" => "invalid_role"} = json_response(conn, 422)
    end

    test "unknown app or user is 404", %{conn: conn} do
      {app, _secret} = app_fixture()

      conn = put(conn, ~p"/api/v1/apps/0/roles/0", role: "admin")
      assert %{"error" => "not_found"} = json_response(conn, 404)

      conn = put(conn, ~p"/api/v1/apps/#{app.id}/roles/0", role: "admin")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "DELETE /api/v1/apps/:id/roles/:user_id" do
    test "removes the assignment", %{conn: conn} do
      {app, _secret} = app_fixture()
      user = You.AccountsFixtures.user_fixture()
      {:ok, _} = You.Roles.set_role(app, user, "admin")

      conn = delete(conn, ~p"/api/v1/apps/#{app.id}/roles/#{user.id}")

      assert response(conn, 204)
      assert You.Roles.role_for(app.slug, user.id) == "user"
    end
  end
end
