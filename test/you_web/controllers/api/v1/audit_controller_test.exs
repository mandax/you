defmodule YouWeb.API.V1.AuditControllerTest do
  use YouWeb.ConnCase, async: false

  setup %{conn: conn} do
    previous = Application.get_env(:you, :api_token)
    Application.put_env(:you, :api_token, "test-api-token")
    on_exit(fn -> Application.put_env(:you, :api_token, previous) end)

    %{conn: put_req_header(conn, "authorization", "Bearer test-api-token")}
  end

  test "GET /api/v1/audit returns recent events as a list", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/audit")

    assert %{"data" => events} = json_response(conn, 200)
    assert is_list(events)
  end
end
