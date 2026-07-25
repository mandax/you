defmodule YouWeb.API.V1.UsersControllerTest do
  use YouWeb.ConnCase, async: false

  alias You.Accounts
  alias You.AccountsFixtures

  setup %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer test-api-token")
    %{conn: conn}
  end

  describe "GET /api/v1/users" do
    test "lists users without secrets", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = get(conn, ~p"/api/v1/users")
      assert %{"data" => users} = json_response(conn, 200)

      assert %{
               "id" => id,
               "email" => email,
               "is_admin" => false,
               "confirmed" => true,
               "inserted_at" => _
             } = Enum.find(users, &(&1["id"] == user.id))

      assert id == user.id
      assert email == user.email

      refute Enum.any?(users, &Map.has_key?(&1, "hashed_password"))
      refute Enum.any?(users, &Map.has_key?(&1, "password"))
      refute Enum.any?(users, &Map.has_key?(&1, "totp_secret"))
    end
  end

  describe "GET /api/v1/users/:id" do
    test "returns one user", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = get(conn, ~p"/api/v1/users/#{user.id}")
      assert %{"data" => %{"id" => id, "email" => email}} = json_response(conn, 200)
      assert id == user.id
      assert email == user.email
    end

    test "unknown id is 404", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/users/0")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "malformed id is 404", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/users/abc")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "POST /api/v1/users" do
    test "creates a confirmed user with a usable password", %{conn: conn} do
      email = AccountsFixtures.unique_user_email()
      password = AccountsFixtures.valid_user_password()

      conn = post(conn, ~p"/api/v1/users", %{"email" => email, "password" => password})

      assert %{"data" => %{"email" => ^email, "confirmed" => true}} =
               json_response(conn, 201)

      user = Accounts.get_user_by_email(email)
      assert user.hashed_password
      assert Accounts.get_user_by_email_and_password(email, password)
    end

    test "invalid email is 422 with changeset errors", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/users", %{
          "email" => "not-an-email",
          "password" => AccountsFixtures.valid_user_password()
        })

      assert %{"error" => "validation_failed", "details" => %{"email" => [_ | _]}} =
               json_response(conn, 422)
    end

    test "short password is 422 with changeset errors", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/users", %{
          "email" => AccountsFixtures.unique_user_email(),
          "password" => "short"
        })

      assert %{"error" => "validation_failed", "details" => %{"password" => [_ | _]}} =
               json_response(conn, 422)
    end

    test "duplicate email is 422", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        post(conn, ~p"/api/v1/users", %{
          "email" => user.email,
          "password" => AccountsFixtures.valid_user_password()
        })

      assert %{"error" => "validation_failed", "details" => %{"email" => [_ | _]}} =
               json_response(conn, 422)
    end
  end

  describe "POST /api/v1/users/:id/logout" do
    test "revokes all sessions and tokens", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.get_user_by_session_token(token)

      conn = post(conn, ~p"/api/v1/users/#{user.id}/logout")
      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == user.id

      refute Accounts.get_user_by_session_token(token)
    end

    test "unknown id is 404", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/users/0/logout")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "DELETE /api/v1/users/:id" do
    test "anonymizes the user instead of hard-deleting", %{conn: conn} do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      original_email = user.email

      conn = delete(conn, ~p"/api/v1/users/#{user.id}")

      assert %{"data" => %{"id" => id, "email" => redacted, "confirmed" => false}} =
               json_response(conn, 200)

      assert id == user.id
      assert String.starts_with?(redacted, "redacted-")

      anonymized = Accounts.get_user!(user.id)
      assert anonymized.email == redacted
      refute anonymized.email == original_email
      assert is_nil(anonymized.hashed_password)
    end

    test "unknown id is 404", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/users/0")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
