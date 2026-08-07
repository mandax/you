defmodule YouWeb.CanonicalHostRoutingTest do
  @moduledoc """
  #123: which routes answer on which host once an app host exists.

  Discovery/JWKS 302 to canonical (there is exactly one issuer); the OAuth
  machine endpoints refuse with a 4xx instead of redirecting (a redirect on
  a POST fails silently for most OAuth clients); `/console/*` and
  `/users/settings/*` 302 to canonical (You's own surfaces, not an app's);
  and browser auth pages — the login page above all — do not redirect at
  all, since serving them on the app host is the entire point of #121.

  Every one of these is gated by `You.Hosting.enabled?/0` — off, or with no
  template, none of this fires and every route answers exactly as it did
  before #121/#123, which the first describe block below pins directly.
  """

  use YouWeb.ConnCase, async: false

  @app_host "acme.example.com"
  @unknown_host "nobody-owns-this.example.net"

  defp enable_hostnames! do
    You.Settings.set(:hostname_template, "{label}.example.com")
    You.Settings.set(:feature_app_hostnames, true)

    on_exit(fn ->
      You.Settings.set(:feature_app_hostnames, false)
      You.Settings.set(:hostname_template, "")
    end)
  end

  defp with_host(conn, host), do: %{conn | host: host}

  describe "feature off (default): byte-identical to before #121/#123" do
    test "discovery is served, not redirected, from a non-canonical host", %{conn: conn} do
      conn = conn |> with_host(@app_host) |> get(~p"/.well-known/openid-configuration")
      assert json_response(conn, 200)
    end

    test "the token endpoint is served, not refused, from a non-canonical host", %{conn: conn} do
      conn = conn |> with_host(@app_host) |> post(~p"/oauth/token", %{})
      # A 400 for the missing `code` param, not the canonical-only refusal —
      # distinguished by the description, since both use `error: "invalid_request"`.
      assert %{"error_description" => description} = json_response(conn, 400)
      refute description =~ "canonical issuer"
    end

    test "/console is served (subject only to auth), not redirected", %{conn: conn} do
      conn = conn |> with_host(@app_host) |> get(~p"/console")
      assert redirected_to(conn) =~ "/users/log-in"
      refute redirected_to(conn) =~ @app_host
    end
  end

  describe "discovery and JWKS 302 to canonical, preserving path and query" do
    setup do
      enable_hostnames!()
      :ok
    end

    test "discovery redirects, and never to the request host", %{conn: conn} do
      conn =
        conn
        |> with_host(@app_host)
        |> get(~p"/.well-known/openid-configuration?foo=bar")

      location = redirected_to(conn, 302)
      uri = URI.parse(location)
      assert uri.host == YouWeb.Endpoint.host()
      assert uri.path == "/.well-known/openid-configuration"
      assert uri.query == "foo=bar"
    end

    test "jwks redirects the same way", %{conn: conn} do
      conn = conn |> with_host(@app_host) |> get(~p"/.well-known/jwks.json")
      assert URI.parse(redirected_to(conn, 302)).host == YouWeb.Endpoint.host()
    end

    test "an unrecognised host redirects too — canonical-only is unconditional on host, not on resolution",
         %{
           conn: conn
         } do
      conn = conn |> with_host(@unknown_host) |> get(~p"/.well-known/openid-configuration")
      assert URI.parse(redirected_to(conn, 302)).host == YouWeb.Endpoint.host()
    end

    test "the canonical host itself is never redirected", %{conn: conn} do
      conn =
        conn |> with_host(YouWeb.Endpoint.host()) |> get(~p"/.well-known/openid-configuration")

      assert json_response(conn, 200)
    end
  end

  describe "OAuth machine endpoints refuse with a 4xx, never a redirect" do
    setup do
      enable_hostnames!()
      :ok
    end

    test "token endpoint off canonical names the canonical issuer, not a redirect", %{conn: conn} do
      conn = conn |> with_host(@app_host) |> post(~p"/oauth/token", %{})

      refute conn.status in 300..399

      assert %{"error" => "invalid_request", "error_description" => description} =
               json_response(conn, 400)

      assert description =~ YouWeb.Endpoint.host()
    end

    test "introspect and revoke refuse the same way", %{conn: conn} do
      for path <- [~p"/oauth/introspect", ~p"/oauth/revoke"] do
        conn = conn |> with_host(@app_host) |> post(path, %{})
        refute conn.status in 300..399
        assert %{"error" => "invalid_request"} = json_response(conn, 400)
      end
    end

    test "the token endpoint on canonical is unaffected (still evaluates the grant)", %{
      conn: conn
    } do
      conn = conn |> with_host(YouWeb.Endpoint.host()) |> post(~p"/oauth/token", %{})
      assert %{"error_description" => description} = json_response(conn, 400)
      refute description =~ "canonical issuer"
    end
  end

  describe "/console and /users/settings 302 to canonical" do
    setup do
      enable_hostnames!()
      :ok
    end

    test "/console redirects before authentication is even checked", %{conn: conn} do
      conn = conn |> with_host(@app_host) |> get(~p"/console")

      location = redirected_to(conn, 302)
      assert URI.parse(location).host == YouWeb.Endpoint.host()
      assert URI.parse(location).path == "/console"
    end

    test "/console/settings/mail redirects, preserving the tab path", %{conn: conn} do
      conn = conn |> with_host(@app_host) |> get(~p"/console/settings/mail")
      assert URI.parse(redirected_to(conn, 302)).path == "/console/settings/mail"
    end

    test "/users/settings redirects to canonical for a logged-in user", %{conn: conn} do
      user = You.AccountsFixtures.user_fixture()
      conn = conn |> YouWeb.ConnCase.log_in_user(user) |> with_host(@app_host)

      conn = get(conn, ~p"/users/settings")
      assert URI.parse(redirected_to(conn, 302)).host == YouWeb.Endpoint.host()
    end

    test "/users/dashboard does NOT redirect — only /users/settings does", %{conn: conn} do
      user = You.AccountsFixtures.user_fixture()
      conn = conn |> YouWeb.ConnCase.log_in_user(user) |> with_host(@app_host)

      conn = get(conn, ~p"/users/dashboard")
      assert conn.status == 200
    end
  end

  describe "browser auth pages never redirect across hosts" do
    setup do
      enable_hostnames!()
      :ok
    end

    test "the login page renders on an app host instead of redirecting", %{conn: conn} do
      conn = conn |> with_host(@app_host) |> get(~p"/users/log-in")
      assert html_response(conn, 200)
    end

    test "the login page renders on an unrecognised host too — unbranded, but served", %{
      conn: conn
    } do
      conn = conn |> with_host(@unknown_host) |> get(~p"/users/log-in")
      assert html_response(conn, 200)
    end
  end

  describe "the social sign-in button on an app host links to canonical with a signed ctx" do
    @google_attrs %{
      "slug" => "google",
      "display_name" => "Google",
      "kind" => "google",
      "client_id" => "gid",
      "client_secret" => "gsecret",
      "issuer" => "https://accounts.google.com",
      "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
      "token_url" => "https://oauth2.googleapis.com/token",
      "userinfo_url" => "https://openidconnect.googleapis.com/v1/userinfo",
      "scopes" => "openid email profile"
    }

    setup do
      enable_hostnames!()
      {:ok, _provider} = You.IdentityProviders.create_provider(@google_attrs)
      :ok
    end

    test "on the canonical host the button is a plain relative link", %{conn: conn} do
      conn = conn |> with_host(YouWeb.Endpoint.host()) |> get(~p"/users/log-in")
      assert html_response(conn, 200) =~ ~s(href="/auth/google")
    end

    test "on an app host the button points at canonical with a verifiable ctx", %{conn: conn} do
      conn = conn |> with_host(@app_host) |> get(~p"/users/log-in")
      body = html_response(conn, 200)

      [_, href] = Regex.run(~r{href="(https?://[^"]*/auth/google\?[^"]*)"}, body)
      uri = URI.parse(decode_html_entities(href))

      assert uri.host == YouWeb.Endpoint.host()
      refute uri.host == @app_host

      %{"ctx" => ctx} = URI.decode_query(uri.query)
      assert {:ok, _attrs} = You.IdentityProviders.verify_ctx(ctx)
    end

    defp decode_html_entities(str), do: String.replace(str, "&amp;", "&")
  end

  describe "the redirect target is configuration, never the request" do
    setup do
      enable_hostnames!()
      :ok
    end

    test "a forged Host cannot steer the console redirect anywhere but canonical", %{conn: conn} do
      forged = "attacker-controls-this.example.net"
      conn = conn |> with_host(forged) |> get(~p"/console")

      location = redirected_to(conn, 302)
      refute URI.parse(location).host == forged
      assert URI.parse(location).host == YouWeb.Endpoint.host()
    end
  end
end
