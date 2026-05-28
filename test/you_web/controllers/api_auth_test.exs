defmodule YouWeb.ApiAuthTest do
  use YouWeb.ConnCase, async: false

  alias You.AccountsFixtures

  describe "POST /api/login" do
    test "returns JWT for valid email and password" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      conn =
        post(build_conn(), ~p"/api/login", %{
          email: user.email,
          password: AccountsFixtures.valid_user_password()
        })

      assert json_response(conn, 200)["jwt"]
    end

    test "returns 401 for invalid password" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      conn =
        post(build_conn(), ~p"/api/login", %{
          email: user.email,
          password: "wrong password"
        })

      assert json_response(conn, 401)
    end

    test "returns 401 for unknown email" do
      conn =
        post(build_conn(), ~p"/api/login", %{
          email: "nonexistent@example.com",
          password: "some password"
        })

      assert json_response(conn, 401)
    end
  end

  describe "DELETE /api/logout" do
    test "revokes the JWT in the Authorization header" do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      login_conn =
        post(build_conn(), ~p"/api/login", %{
          email: user.email,
          password: AccountsFixtures.valid_user_password()
        })

      %{"jwt" => jwt} = json_response(login_conn, 200)

      # Can verify the token before logout
      assert {:ok, _claims} = You.JWT.verify(jwt)

      # Logout
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{jwt}")
        |> delete(~p"/api/logout")

      assert response(conn, 204)

      # Token is now revoked
      assert {:error, :revoked} = You.JWT.verify(jwt)
    end

    test "returns 401 without Authorization header" do
      conn = delete(build_conn(), ~p"/api/logout")
      assert json_response(conn, 401)
    end
  end
end
