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

  # config/test.exs pins the WebAuthn RP ID to "example.com". The default
  # ConnTest host ("www.example.com") is a subdomain of it, which is what the
  # rest of this file's requests exercise — the canonical, qualifying host.
  # These cover the boundary: a host outside the RP ID's zone is refused
  # rather than served a mismatched ceremony.
  describe "passkey availability by host" do
    test "a host under the configured RP ID is offered passkeys", %{conn: conn} do
      conn = %{conn | host: "demo.example.com"}

      assert %{"publicKey" => %{"challenge" => _}} =
               conn
               |> init_test_session(callback_url: nil)
               |> post(~p"/users/log-in/passkey/start", %{})
               |> json_response(200)
    end

    test "a host outside the configured RP ID's zone is refused", %{conn: conn} do
      conn = %{conn | host: "example.org"}

      assert %{"error" => error} =
               conn
               |> init_test_session(callback_url: nil)
               |> post(~p"/users/log-in/passkey/start", %{})
               |> json_response(403)

      assert error =~ "not available"
    end
  end

  # start_registration/2 and finish_registration/2 are behind
  # :require_authenticated_user, so these need a signed-in user rather than
  # the bare conn the authentication tests above use.
  describe "passkey registration gating" do
    setup :register_and_log_in_user

    test "start is refused on a host outside the configured RP ID's zone", %{conn: conn} do
      conn = %{conn | host: "example.org"}

      assert %{"error" => error} =
               conn
               |> post(~p"/users/settings/passkeys/register/start", %{})
               |> json_response(403)

      assert error =~ "not available"
    end

    test "finish is refused on a host outside the configured RP ID's zone", %{conn: conn} do
      conn = %{conn | host: "example.org"}

      assert %{"error" => error} =
               conn
               |> post(~p"/users/settings/passkeys/register/finish", %{})
               |> json_response(403)

      assert error =~ "not available"
    end

    test "start is offered on a host under the configured RP ID", %{conn: conn} do
      conn = %{conn | host: "demo.example.com"}

      assert %{"publicKey" => %{"challenge" => _}} =
               conn
               |> post(~p"/users/settings/passkeys/register/start", %{})
               |> json_response(200)
    end

    test "a disabled instance feature refuses start on the canonical host too", %{conn: conn} do
      You.Settings.set(:feature_passkeys, false)
      on_exit(fn -> You.Settings.set(:feature_passkeys, true) end)

      assert %{"error" => _} =
               conn
               |> post(~p"/users/settings/passkeys/register/start", %{})
               |> json_response(403)
    end

    # /users/settings/passkeys manages the account's own credentials, not a
    # login for any particular app — an app the user merely arrived through
    # (its callback_url left over in session) restricting itself to
    # ["password"] must not block adding a passkey to the account.
    test "an in-flight app restricted to password does not block enrollment", %{conn: conn} do
      {:ok, app, _secret} =
        You.Admin.create_app(%{
          slug: "pw-only-enrollment",
          name: "Password Only",
          callback_url: "https://pw-only.example.com/cb"
        })

      {:ok, app} = You.Admin.update_app(app, %{"enabled_methods" => ["password"]})
      refute "passkey" in YouWeb.AuthMethods.enabled_methods(app, conn.host)

      conn = init_test_session(conn, callback_url: app.callback_url)

      assert %{"publicKey" => %{"challenge" => _}} =
               conn
               |> post(~p"/users/settings/passkeys/register/start", %{})
               |> json_response(200)
    end
  end

  # Every Wax.new_registration_challenge/1 and Wax.new_authentication_challenge/1
  # call must pass origin_verify_fun: {You.WebAuthn, :origin_matches?, []} —
  # Wax's own default (Wax.origins_match?/2) is an exact match against the
  # single configured origin and would silently refuse every subdomain,
  # with the render gate still saying the host qualifies. The challenge
  # round-trips through the session, so the wiring is directly checkable.
  describe "origin_verify_fun wiring" do
    setup :register_and_log_in_user

    test "registration challenges carry it", %{conn: conn} do
      conn = post(conn, ~p"/users/settings/passkeys/register/start", %{})

      assert get_session(conn, :webauthn_challenge).origin_verify_fun ==
               {You.WebAuthn, :origin_matches?, []}
    end

    test "authentication challenges with no allow_credentials carry it", %{conn: conn} do
      conn =
        conn
        |> init_test_session(callback_url: nil)
        |> post(~p"/users/log-in/passkey/start", %{})

      assert get_session(conn, :webauthn_challenge).origin_verify_fun ==
               {You.WebAuthn, :origin_matches?, []}
    end

    test "authentication challenges with allow_credentials carry it", %{conn: conn, user: user} do
      {:ok, _passkey} =
        You.Accounts.register_passkey(user, %{
          credential_id: :crypto.strong_rand_bytes(16),
          public_key: %{1 => 2, 3 => -7, -1 => 1, -2 => <<0::256>>, -3 => <<0::256>>},
          sign_count: 0
        })

      conn =
        conn
        |> init_test_session(callback_url: nil)
        |> post(~p"/users/log-in/passkey/start", %{"email" => user.email})

      assert get_session(conn, :webauthn_challenge).origin_verify_fun ==
               {You.WebAuthn, :origin_matches?, []}
    end
  end

  # The management page (view/remove) is not host-restricted — only adding a
  # new passkey is, since that's the part a non-qualifying host can't
  # actually complete.
  describe "passkey settings page" do
    setup :register_and_log_in_user

    test "offers Add passkey on a host under the configured RP ID", %{conn: conn} do
      conn = %{conn | host: "demo.example.com"}

      html = conn |> get(~p"/users/settings/passkeys") |> html_response(200)

      assert html =~ ~s(id="register-passkey")
    end

    test "omits Add passkey, with an explanation naming the hostname, on a non-qualifying host",
         %{conn: conn} do
      conn = %{conn | host: "example.org"}

      html = conn |> get(~p"/users/settings/passkeys") |> html_response(200)

      refute html =~ ~s(id="register-passkey")
      assert html =~ "isn't available on this hostname"
    end

    # The hostname copy is wrong advice when the real cause is the instance
    # switch — the user is already on a qualifying host, and re-visiting it
    # changes nothing. Each cause gets its own message.
    test "omits Add passkey, with a different explanation, when the feature is off", %{
      conn: conn
    } do
      You.Settings.set(:feature_passkeys, false)
      on_exit(fn -> You.Settings.set(:feature_passkeys, true) end)

      html = conn |> get(~p"/users/settings/passkeys") |> html_response(200)

      refute html =~ ~s(id="register-passkey")
      refute html =~ "isn't available on this hostname"
      assert html =~ "turned off for this instance"
    end

    test "still lists and allows managing existing passkeys on a non-qualifying host", %{
      conn: conn,
      user: user
    } do
      {:ok, passkey} =
        You.Accounts.register_passkey(user, %{
          credential_id: :crypto.strong_rand_bytes(16),
          public_key: %{1 => 2, 3 => -7, -1 => 1, -2 => <<0::256>>, -3 => <<0::256>>},
          sign_count: 0,
          label: "Existing key"
        })

      conn = %{conn | host: "example.org"}

      html = conn |> get(~p"/users/settings/passkeys") |> html_response(200)

      assert html =~ "Existing key"
      assert html =~ ~p"/users/settings/passkeys/#{passkey.id}"
    end
  end
end
