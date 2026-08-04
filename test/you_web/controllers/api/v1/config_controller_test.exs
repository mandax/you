defmodule YouWeb.API.V1.ConfigControllerTest do
  @moduledoc """
  Export and import landed in #110 as console-only. CI promoting a staging
  configuration, and backup automation that does not depend on someone
  clicking, need the same thing over HTTP.
  """
  use YouWeb.ConnCase, async: false

  alias You.Settings

  @password "a-long-enough-password"

  setup %{conn: conn} do
    Settings.set(:api_token, "test-api-token")

    %{
      conn:
        conn
        |> put_req_header("authorization", "Bearer test-api-token")
        |> put_req_header("content-type", "application/json")
    }
  end

  defp export!(conn, password \\ @password) do
    conn |> post(~p"/api/v1/config/bundle", %{"password" => password}) |> response(200)
  end

  describe "POST /api/v1/config/bundle" do
    test "seals the instance's configuration", %{conn: conn} do
      Settings.set(:jwt_expiry_hours, 6)

      bundle = export!(conn)

      assert bundle =~ "you.config.v1"
      assert {:ok, payload} = You.Config.Vault.open(bundle, @password)
      assert payload["settings"]["jwt_expiry_hours"] == 6
    end

    test "does not leak secrets in the clear", %{conn: conn} do
      Settings.set(:smtp_username, "postmaster@example.com")

      refute export!(conn) =~ "postmaster@example.com"
    end

    test "refuses a password shorter than the vault's minimum", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/config/bundle", %{"password" => "short"})

      assert %{"error" => "password_too_short"} = json_response(conn, 422)
    end

    test "refuses a request with no password at all", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/config/bundle", %{})

      assert %{"error" => "password_required"} = json_response(conn, 422)
    end

    test "is closed to an unauthenticated caller", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post(~p"/api/v1/config/bundle", %{"password" => @password})

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/v1/config/bundle/preview" do
    test "reports what an import would change without writing", %{conn: conn} do
      Settings.set(:jwt_expiry_hours, 9)
      bundle = export!(conn)
      Settings.set(:jwt_expiry_hours, 1)

      conn =
        post(conn, ~p"/api/v1/config/bundle/preview", %{
          "password" => @password,
          "bundle" => bundle
        })

      assert %{"data" => preview} = json_response(conn, 200)
      assert Enum.any?(preview["settings"], &(&1["key"] == "jwt_expiry_hours"))
      assert Settings.get(:jwt_expiry_hours) == 1
    end

    test "a wrong password is 401, not 422", %{conn: conn} do
      bundle = export!(conn)

      conn =
        post(conn, ~p"/api/v1/config/bundle/preview", %{
          "password" => "a-different-password",
          "bundle" => bundle
        })

      assert %{"error" => "wrong_password"} = json_response(conn, 401)
    end

    test "something that is not a bundle is refused", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/config/bundle/preview", %{
          "password" => @password,
          "bundle" => "hello"
        })

      assert %{"error" => "malformed"} = json_response(conn, 422)
    end

    test "a request missing the bundle is refused", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/config/bundle/preview", %{"password" => @password})

      assert %{"error" => "password_and_bundle_required"} = json_response(conn, 422)
    end
  end

  describe "POST /api/v1/config/bundle/import" do
    test "applies the bundle and reports a count per section", %{conn: conn} do
      Settings.set(:jwt_expiry_hours, 6)
      bundle = export!(conn)
      Settings.set(:jwt_expiry_hours, 1)

      conn =
        post(conn, ~p"/api/v1/config/bundle/import", %{
          "password" => @password,
          "bundle" => bundle
        })

      assert %{"data" => summary} = json_response(conn, 200)
      assert summary["settings"] > 0
      assert Settings.get(:jwt_expiry_hours) == 6
    end

    test "refuses to carry instance identity in, as the console does", %{conn: conn} do
      Settings.set(:api_token, "test-api-token")
      bundle = export!(conn)

      assert {:ok, payload} = You.Config.Vault.open(bundle, @password)
      refute Map.has_key?(payload["settings"], "api_token")
      refute Map.has_key?(payload["settings"], "erlang_cookie")
      refute Map.has_key?(payload["settings"], "scim_bearer_token")
    end

    test "leaves an audit trail", %{conn: conn} do
      test_pid = self()
      handler = "config-api-audit-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:you, :audit, :admin, :action],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:audit, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      export!(conn)

      assert_receive {:audit, %{action: "export_config_bundle", via: "api"}}, 1_000
    end
  end
end
