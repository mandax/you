defmodule YouWeb.PageControllerTest do
  use YouWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "One login for every Elixir service"
    assert html_response(conn, 200) =~ "Self-hosted identity for the BEAM"
  end
end
