defmodule YouWeb.PageControllerTest do
  use YouWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "One login for every service you run"
    assert html_response(conn, 200) =~ "credentials stay on your hardware"
  end
end
