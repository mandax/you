defmodule YouWeb.WebAuthnControllerTest do
  use YouWeb.ConnCase, async: false

  # Hiding the passkey button is not gating: the endpoints are reachable
  # directly, so they have to reject a disabled method themselves. These cover
  # the three states — no app in flight, an app that allows passkeys, and each
  # of the two switches that can turn them off.
  describe "passkey authentication gating" do
    setup do
      {:ok, app, _secret} =
        You.Admin.create_app(%{
          slug: "pk-gate",
          name: "Passkey Gate",
          callback_url: "https://pk-gate.example.com/cb"
        })

      %{app: app}
    end

    defp start_authentication(conn, callback_url \\ nil) do
      conn
      |> init_test_session(callback_url: callback_url)
      |> post(~p"/users/log-in/passkey/start", %{})
    end

    test "a plain sign-in with no app in flight is allowed", %{conn: conn} do
      assert %{"publicKey" => %{"challenge" => _}} =
               conn |> start_authentication() |> json_response(200)
    end

    test "an app that follows the instance is allowed", %{conn: conn, app: app} do
      assert app.enabled_methods == nil

      assert %{"publicKey" => %{"challenge" => _}} =
               conn |> start_authentication(app.callback_url) |> json_response(200)
    end

    test "an app that pins passkey among its methods is allowed", %{conn: conn, app: app} do
      {:ok, app} = You.Admin.update_app(app, %{"enabled_methods" => ["password", "passkey"]})

      assert %{"publicKey" => %{"challenge" => _}} =
               conn |> start_authentication(app.callback_url) |> json_response(200)
    end

    test "an app that omits passkey is refused", %{conn: conn, app: app} do
      {:ok, app} = You.Admin.update_app(app, %{"enabled_methods" => ["password"]})

      assert %{"error" => error} =
               conn |> start_authentication(app.callback_url) |> json_response(403)

      assert error =~ "not available"
    end

    test "a disabled instance feature refuses even an app that allows passkeys", %{
      conn: conn,
      app: app
    } do
      {:ok, app} = You.Admin.update_app(app, %{"enabled_methods" => ["password", "passkey"]})

      You.Settings.set(:feature_passkeys, false)
      on_exit(fn -> You.Settings.set(:feature_passkeys, true) end)

      assert %{"error" => _} =
               conn |> start_authentication(app.callback_url) |> json_response(403)
    end

    test "a disabled instance feature refuses a plain sign-in too", %{conn: conn} do
      You.Settings.set(:feature_passkeys, false)
      on_exit(fn -> You.Settings.set(:feature_passkeys, true) end)

      assert %{"error" => _} = conn |> start_authentication() |> json_response(403)
    end

    test "finish is gated as well as start", %{conn: conn, app: app} do
      {:ok, app} = You.Admin.update_app(app, %{"enabled_methods" => ["password"]})

      conn =
        conn
        |> init_test_session(callback_url: app.callback_url)
        |> post(~p"/users/log-in/passkey/finish", %{})

      assert %{"error" => error} = json_response(conn, 403)
      assert error =~ "not available"
    end
  end
end
