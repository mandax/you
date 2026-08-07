defmodule YouWeb.RequestHostTest do
  @moduledoc """
  Groundwork for per-app hostnames (#121): every user-facing link You emails
  or hands a LiveView builds against the host the flow started on, not the
  instance-wide canonical host — because sessions are host-local, and a link
  pointing at a different host lands the user in a different session.

  Today there is exactly one host, so these tests set the request host
  explicitly to prove the plumbing threads it through correctly, ahead of
  #121 giving apps their own hostnames.

  Two categories are pinned to the canonical host on purpose and are
  asserted to *ignore* the request host: the federated `redirect_uri`
  (registered with upstream providers against the canonical host) and the
  machine endpoints (`iss`, JWKS, discovery, the token endpoint).
  """

  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import You.AccountsFixtures

  alias You.Accounts
  alias You.Admin
  alias You.IdentityProviders
  alias You.JWT

  @request_host "acme.example.com"

  defp with_request_host(conn), do: %{conn | host: @request_host}

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

  defp assert_email_url_host(host) do
    assert_received {:email, email}
    [url] = Regex.run(~r{https?://[^\s]+}, email.text_body)
    assert URI.parse(url).host == host
  end

  describe "magic link login request" do
    test "the emailed link carries the host the request arrived on", %{conn: conn} do
      user = user_fixture()
      flush_mailbox()

      conn
      |> with_request_host()
      |> post(~p"/users/log-in", %{"user" => %{"email" => user.email}})

      assert_email_url_host(@request_host)
    end
  end

  describe "registration confirmation" do
    test "the emailed confirmation link carries the request host", %{conn: conn} do
      email = unique_user_email()

      conn
      |> with_request_host()
      |> post(~p"/users/register", %{"user" => valid_user_attributes(email: email)})

      assert_email_url_host(@request_host)
    end
  end

  describe "password reset" do
    test "the emailed reset link carries the request host", %{conn: conn} do
      user = user_fixture()
      flush_mailbox()

      conn
      |> with_request_host()
      |> post(~p"/users/reset-password", %{"user" => %{"email" => user.email}})

      assert_email_url_host(@request_host)
    end
  end

  describe "email change" do
    test "the emailed confirmation link carries the request host", %{conn: conn} do
      user = user_fixture()
      flush_mailbox()
      conn = log_in_user(conn, user)

      conn
      |> with_request_host()
      |> put(~p"/users/settings", %{
        "action" => "update_email",
        "user" => %{"email" => unique_user_email()}
      })

      assert_email_url_host(@request_host)
    end
  end

  describe "invitations" do
    test "the emailed acceptance link carries the host the console request arrived on", %{
      conn: conn
    } do
      admin = user_fixture()
      flush_mailbox()
      Admin.promote_admin!(admin)

      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "invite-host-#{System.unique_integer([:positive])}",
          name: "Invite Host",
          callback_url: "https://invite-host.example.com/cb"
        })

      conn = conn |> with_request_host() |> log_in_user(admin)
      {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.slug}/members")

      render_submit(lv, "invite_member", %{"email" => unique_user_email(), "role" => "user"})

      assert_email_url_host(@request_host)
    end
  end

  describe "machine endpoints ignore the request host" do
    test "discovery stays on the canonical host", %{conn: conn} do
      conn = conn |> with_request_host() |> get(~p"/.well-known/openid-configuration")

      assert %{"issuer" => issuer} = json_response(conn, 200)
      assert issuer == YouWeb.Endpoint.url()
      refute issuer =~ @request_host
    end

    test "jwks is unaffected by the request host", %{conn: conn} do
      conn = conn |> with_request_host() |> get(~p"/.well-known/jwks.json")

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
        |> with_request_host()
        |> post(~p"/oauth/token", code: code, client_id: app.slug, client_secret: secret)

      assert %{"id_token" => id_token} = json_response(conn, 200)
      assert {:ok, claims} = JWT.verify(id_token)
      assert claims["iss"] == YouWeb.Endpoint.url()
      refute claims["iss"] =~ @request_host
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

      conn = conn |> with_request_host() |> get(~p"/auth/google")

      location = redirected_to(conn, 302)
      redirect_uri = URI.decode_query(URI.parse(location).query) |> Map.fetch!("redirect_uri")

      refute URI.parse(redirect_uri).host == @request_host
      assert URI.parse(redirect_uri).host == URI.parse(YouWeb.Endpoint.url()).host
    end
  end

  describe "social login" do
    # Exercises the full callback: a github-kind provider (no userinfo
    # endpoint) routed through its own adapter, backed by a local Bandit
    # server standing in for GitHub. Confirms login still completes when the
    # request that started the flow carries a non-canonical host.
    test "still completes with a non-canonical request host", %{conn: conn} do
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
        |> with_request_host()
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
