defmodule YouWeb.AccessDataTest do
  use YouWeb.ConnCase

  setup :register_and_log_in_user

  describe "GET /users/settings/access_data" do
    test "returns user personal data as JSON", %{conn: conn, user: user} do
      conn = get(conn, ~p"/users/settings/access_data")
      assert json_response(conn, 200)["email"] == user.email
      assert json_response(conn, 200)["totp_enabled"] == false
      assert Map.has_key?(json_response(conn, 200), "apps")
    end
  end
end
