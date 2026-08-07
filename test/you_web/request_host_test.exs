defmodule YouWeb.RequestHostTest do
  @moduledoc """
  `YouWeb.RequestURL` builds every user-facing email link (magic link,
  confirmation, password reset, email change, invitation) on the host a
  request arrived on — but only when that host is allowlisted, never because
  it showed up in the `Host` header.

  That distinction is the point of this file. `conn.host` is attacker
  controlled: without the allowlist, a forged `Host` on `POST
  /users/reset-password` would email a *live* reset token pointing at a host
  the attacker runs, and the same forgery on the magic-link path would do it
  to a token that is not a reset step but a full authentication credential —
  one click is account takeover, not merely a broken-looking email.

  Today `YouWeb.RequestURL.allowed_hosts/0` is exactly the canonical host, so
  there is no *allowed* non-canonical host to prove the pass-through case
  with yet — that arrives with #121 (per-app hostnames), which is meant to
  extend the allowlist with hosts that resolve to a configured app, not with
  whatever the header claims. Until then, every test below that used to
  thread a distinct host through the flow instead asserts the fallback: a
  forged (non-allowlisted) host must never appear in an emailed link, and
  the canonical host must appear in its place.
  """

  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import You.AccountsFixtures

  alias You.Accounts
  alias You.Admin
  alias You.IdentityProviders
  alias You.JWT

  # Stands in for an attacker-forged `Host` header throughout this file. It
  # must never appear in an emailed link.
  @forged_host "evil.example.net"

  defp with_forged_host(conn), do: %{conn | host: @forged_host}
  defp with_canonical_host(conn), do: %{conn | host: YouWeb.Endpoint.host()}

  # `user_fixture/1` confirms its user via its own magic-link send, which
  # queues an unrelated {:email, _} message ahead of the one the test cares
  # about — drain it so `assert_email_url_host/1` looks at the right send.
  defp flush_mailbox do
    receive do
      {:email, _} -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp emailed_url do
    assert_received {:email, email}
    [url] = Regex.run(~r{https?://[^\s]+}, email.text_body)
    url
  end

  defp assert_email_url_is_canonical do
    host = emailed_url() |> URI.parse() |> Map.fetch!(:host)
    assert host == YouWeb.Endpoint.host()
    refute host == @forged_host
  end

  describe "password reset — reset-poisoning guard" do
    test "a forged Host never reaches the emailed reset link", %{conn: conn} do
      user = user_fixture()
      flush_mailbox()

      conn
      |> with_forged_host()
      |> post(~p"/users/reset-password", %{"user" => %{"email" => user.email}})

      assert_email_url_is_canonical()
    end
  end

  describe "magic link login request — account-takeover guard" do
    # The magic-link token is not a reset step, it *is* an authentication
    # credential: clicking it logs the clicker in. A forged Host that
    # survived into this link would hand the attacker a working login for
    # the victim's account on the first click, so this test guards takeover,
    # not merely a cosmetic URL.
    test "a forged Host never reaches the emailed login link", %{conn: conn} do
      user = user_fixture()
      flush_mailbox()

      conn
      |> with_forged_host()
      |> post(~p"/users/log-in", %{"user" => %{"email" => user.email}})

      assert_email_url_is_canonical()
    end
  end

  describe "the normal path" do
    test "a request on the canonical host still gets a canonical link", %{conn: conn} do
      user = user_fixture()
      flush_mailbox()

      conn
      |> with_canonical_host()
      |> post(~p"/users/log-in", %{"user" => %{"email" => user.email}})

      assert_email_url_is_canonical()
    end
  end

  describe "registration confirmation" do
    test "a forged Host never reaches the emailed confirmation link", %{conn: conn} do
      email = unique_user_email()

      conn
      |> with_forged_host()
      |> post(~p"/users/register", %{"user" => valid_user_attributes(email: email)})

      assert_email_url_is_canonical()
    end
  end

  describe "email change" do
    test "a forged Host never reaches the emailed confirmation link", %{conn: conn} do
      user = user_fixture()
      flush_mailbox()
      conn = log_in_user(conn, user)

      conn
      |> with_forged_host()
      |> put(~p"/users/settings", %{
        "action" => "update_email",
        "user" => %{"email" => unique_user_email()}
      })

      assert_email_url_is_canonical()
    end
  end

  describe "invitations" do
    test "a forged Host never reaches the emailed acceptance link", %{conn: conn} do
      admin = user_fixture()
      flush_mailbox()
      Admin.promote_admin!(admin)

      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "invite-host-#{System.unique_integer([:positive])}",
          name: "Invite Host",
          callback_url: "https://invite-host.example.com/cb"
        })

      conn = conn |> with_forged_host() |> log_in_user(admin)
      {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.slug}/members")

      render_submit(lv, "invite_member", %{"email" => unique_user_email(), "role" => "user"})

      assert_email_url_is_canonical()
    end
  end

  describe "machine endpoints ignore the request host" do
    test "discovery stays on the canonical host", %{conn: conn} do
      conn = conn |> with_forged_host() |> get(~p"/.well-known/openid-configuration")

      assert %{"issuer" => issuer} = json_response(conn, 200)
      assert issuer == YouWeb.Endpoint.url()
      refute issuer =~ @forged_host
    end

    test "jwks is unaffected by the request host", %{conn: conn} do
      conn = conn |> with_forged_host() |> get(~p"/.well-known/jwks.json")

      assert %{"keys" => [_ | _]} = json_response(conn, 200)
    end

    test "the token endpoint issues an id_token whose iss stays canonical", %{conn: conn} do
      user = user_fixture()

      {:ok, app, secret} =
        Admin.create_app(%{
          slug: "iss-host-#{System.unique_integer([:positive])}",
          name: "Iss Host",
          callback_url: "https://iss-host.example.com/cb"
        })

      {:ok, code} = Accounts.generate_auth_code(user, ["email"], nil, app.slug)

      conn =
        conn
        |> with_forged_host()
        |> post(~p"/oauth/token", code: code, client_id: app.slug, client_secret: secret)

      assert %{"id_token" => id_token} = json_response(conn, 200)
      assert {:ok, claims} = JWT.verify(id_token)
      assert claims["iss"] == YouWeb.Endpoint.url()
      refute claims["iss"] =~ @forged_host
    end
  end

  describe "federated redirect_uri ignores the request host" do
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

    test "the authorize redirect's redirect_uri stays on the canonical host", %{conn: conn} do
      {:ok, _provider} = IdentityProviders.create_provider(@google_attrs)

      conn = conn |> with_forged_host() |> get(~p"/auth/google")

      location = redirected_to(conn, 302)
      redirect_uri = URI.decode_query(URI.parse(location).query) |> Map.fetch!("redirect_uri")

      refute URI.parse(redirect_uri).host == @forged_host
      assert URI.parse(redirect_uri).host == URI.parse(YouWeb.Endpoint.url()).host
    end
  end

  describe "social login" do
    # Exercises the full callback: a github-kind provider (no userinfo
    # endpoint) routed through its own adapter, backed by a local Bandit
    # server standing in for GitHub. Confirms login still completes when the
    # request that started the flow carries a forged host.
    test "still completes with a forged request host", %{conn: conn} do
      test_pid = self()
      port = 45_962

      plug = fn c, _opts ->
        send(test_pid, {:hit, c.request_path})

        body =
          case c.request_path do
            "/login/oauth/access_token" ->
              Jason.encode!(%{"access_token" => "gho_x"})

            "/user" ->
              Jason.encode!(%{"id" => 4243, "login" => "octo2"})

            "/user/emails" ->
              Jason.encode!([
                %{"email" => "octo2@example.com", "primary" => true, "verified" => true}
              ])
          end

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      server = start_supervised!({Bandit, plug: plug, port: port, ip: :loopback}, id: make_ref())
      on_exit(fn -> Process.unlink(server) end)
      base = "http://localhost:#{port}"
      Application.put_env(:you, :github_api_base_url, base)
      on_exit(fn -> Application.delete_env(:you, :github_api_base_url) end)

      {:ok, _provider} =
        IdentityProviders.create_provider(%{
          "slug" => "github",
          "display_name" => "GitHub",
          "kind" => "github",
          "client_id" => "cid",
          "client_secret" => "secret",
          "authorize_url" => base <> "/login/oauth/authorize",
          "token_url" => base <> "/login/oauth/access_token",
          "userinfo_url" => "",
          "scopes" => "read:user user:email",
          "enabled" => true
        })

      conn =
        conn
        |> with_forged_host()
        |> init_test_session(oidc_state: "st", oidc_provider: "github")
        |> get(~p"/auth/github/callback", %{"code" => "c", "state" => "st"})

      assert_received {:hit, "/login/oauth/access_token"}
      assert_received {:hit, "/user"}
      assert_received {:hit, "/user/emails"}

      assert You.Repo.get_by(You.Accounts.User, email: "octo2@example.com")
      assert redirected_to(conn)
    end
  end
end
