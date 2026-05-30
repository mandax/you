defmodule YouWeb.PageControllerTest do
  use YouWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "One identity for"
    assert html_response(conn, 200) =~ "You is a simple, secure IAM solution"
  end
end
