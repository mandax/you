defmodule YouWeb.Plugs.ManagementAuthTest do
  use YouWeb.ConnCase, async: false

  setup do
    You.Settings.set(:api_token, "test-api-token")
    :ok
  end

  @token "test-api-token"

  test "no authorization header is 401 invalid_token", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/users")
    assert %{"error" => "invalid_token"} = json_response(conn, 401)
  end

  test "wrong token is 401 invalid_token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-token")
      |> get(~p"/api/v1/users")

    assert %{"error" => "invalid_token"} = json_response(conn, 401)
  end

  test "non-bearer scheme is 401 invalid_token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Token #{@token}")
      |> get(~p"/api/v1/users")

    assert %{"error" => "invalid_token"} = json_response(conn, 401)
  end

  test "correct token passes through", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get(~p"/api/v1/users")

    assert %{"data" => _} = json_response(conn, 200)
  end

  test "an unset api_token disables the API with 403", %{conn: conn} do
    You.Settings.set(:api_token, "")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get(~p"/api/v1/users")

    assert %{"error" => "management_api_disabled"} = json_response(conn, 403)
  end

  test "a whitespace-only api_token disables the API with 403", %{conn: conn} do
    You.Settings.set(:api_token, "   ")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> get(~p"/api/v1/users")

    assert %{"error" => "management_api_disabled"} = json_response(conn, 403)
  end
end
