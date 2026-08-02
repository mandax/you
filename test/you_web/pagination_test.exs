defmodule YouWeb.PaginationTest do
  use YouWeb.ConnCase, async: false

  alias You.AccountsFixtures

  setup do
    for _ <- 1..5, do: AccountsFixtures.user_fixture()
    :ok
  end

  test "scim paging honours startIndex and count", %{conn: conn} do
    You.Settings.set(:scim_bearer_token, "tok")

    body =
      conn
      |> put_req_header("authorization", "Bearer tok")
      |> get("/scim/v2/Users?startIndex=2&count=2")
      |> json_response(200)

    assert body["itemsPerPage"] == 2
    assert body["startIndex"] == 2
    assert body["totalResults"] >= 5
    assert length(body["Resources"]) == 2
  end

  test "management api paging", %{conn: conn} do
    Application.put_env(:you, :api_token, "mgmt")
    on_exit(fn -> Application.delete_env(:you, :api_token) end)

    body =
      conn
      |> put_req_header("authorization", "Bearer mgmt")
      |> get("/api/v1/users?limit=2&offset=1")
      |> json_response(200)

    assert length(body["data"]) == 2
    assert body["meta"]["limit"] == 2
    assert body["meta"]["offset"] == 1
    assert body["meta"]["total"] >= 5
  end
end
