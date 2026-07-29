defmodule YouWeb.FederatedAuthControllerTest do
  use YouWeb.ConnCase, async: false

  alias You.IdentityProviders

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

  defp create_provider!(attrs \\ @google_attrs) do
    {:ok, provider} = IdentityProviders.create_provider(attrs)
    provider
  end

  describe "GET /auth/:provider (authorize)" do
    test "reads the provider from the database, not app env", %{conn: conn} do
      create_provider!()

      conn = get(conn, ~p"/auth/google")

      assert redirected_to(conn, 302) =~ "accounts.google.com/o/oauth2/v2/auth"
      assert redirected_to(conn) =~ "client_id=gid"
    end

    test "rejects an unknown provider slug without raising", %{conn: conn} do
      conn = get(conn, ~p"/auth/does-not-exist")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Unknown authentication provider."
    end

    test "rejects a disabled provider", %{conn: conn} do
      provider = create_provider!()
      {:ok, _disabled} = IdentityProviders.update_provider(provider, %{"enabled" => false})

      conn = get(conn, ~p"/auth/google")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Unknown authentication provider."
    end

    test "an app with enabled_providers: [\"google\"] is rejected for /auth/github", %{
      conn: conn
    } do
      create_provider!()
      create_provider!(%{@google_attrs | "slug" => "github", "display_name" => "GitHub"})

      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "google-only",
          name: "Google Only",
          callback_url: "https://google-only.example.com/cb",
          enabled_providers: ["google"]
        })

      conn =
        conn
        |> init_test_session(callback_url: "https://google-only.example.com/cb")
        |> get(~p"/auth/github")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Unknown authentication provider."
    end

    test "an app with enabled_providers: [\"google\"] is allowed for /auth/google", %{
      conn: conn
    } do
      create_provider!()

      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "google-only",
          name: "Google Only",
          callback_url: "https://google-only.example.com/cb",
          enabled_providers: ["google"]
        })

      conn =
        conn
        |> init_test_session(callback_url: "https://google-only.example.com/cb")
        |> get(~p"/auth/google")

      assert redirected_to(conn, 302) =~ "accounts.google.com"
    end

    test "an app with enabled_providers: nil gets every provider", %{conn: conn} do
      create_provider!()
      create_provider!(%{@google_attrs | "slug" => "github", "display_name" => "GitHub"})

      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "any-provider",
          name: "Any Provider",
          callback_url: "https://any-provider.example.com/cb",
          enabled_providers: nil
        })

      conn =
        conn
        |> init_test_session(callback_url: "https://any-provider.example.com/cb")
        |> get(~p"/auth/github")

      assert redirected_to(conn, 302) =~ "accounts.google.com"
    end
  end

  describe "GET /auth/:provider/callback" do
    test "rejects an unknown provider slug without raising", %{conn: conn} do
      conn = get(conn, ~p"/auth/does-not-exist/callback", %{"code" => "x", "state" => "y"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Authentication failed."
    end

    test "an app with enabled_providers: [\"google\"] is rejected at the callback for github", %{
      conn: conn
    } do
      create_provider!()
      create_provider!(%{@google_attrs | "slug" => "github", "display_name" => "GitHub"})

      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "google-only",
          name: "Google Only",
          callback_url: "https://google-only.example.com/cb",
          enabled_providers: ["google"]
        })

      conn =
        conn
        |> init_test_session(
          callback_url: "https://google-only.example.com/cb",
          oidc_state: "st-123"
        )
        |> get(~p"/auth/github/callback", %{"code" => "x", "state" => "st-123"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Authentication failed."
    end

    test "state mismatch is rejected before any token exchange", %{conn: conn} do
      create_provider!()

      conn =
        conn
        |> init_test_session(oidc_state: "expected")
        |> get(~p"/auth/google/callback", %{"code" => "x", "state" => "wrong"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "state mismatch"
    end
  end

  describe "github provider dispatch" do
    setup do
      original = Application.get_env(:you, :github_api_base_url)
      on_exit(fn -> Application.put_env(:you, :github_api_base_url, original) end)
      :ok
    end

    # GitHub has no userinfo endpoint and no `sub` claim, so a github-kind
    # provider must go through the adapter rather than the generic OIDC fetch.
    # The adapter's own behaviour is covered in identity_providers/github_test.
    test "a github-kind provider routes through the adapter, not the OIDC userinfo fetch",
         %{conn: conn} do
      test_pid = self()
      port = 45_961

      plug = fn c, _opts ->
        send(test_pid, {:hit, c.request_path})

        body =
          case c.request_path do
            "/login/oauth/access_token" ->
              Jason.encode!(%{"access_token" => "gho_x"})

            "/user" ->
              Jason.encode!(%{"id" => 4242, "login" => "octo"})

            "/user/emails" ->
              Jason.encode!([
                %{"email" => "octo@example.com", "primary" => true, "verified" => true}
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

      {:ok, _provider} =
        You.IdentityProviders.create_provider(%{
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
        |> init_test_session(oidc_state: "st", oidc_provider: "github")
        |> get(~p"/auth/github/callback", %{"code" => "c", "state" => "st"})

      assert_received {:hit, "/login/oauth/access_token"}
      assert_received {:hit, "/user"}
      assert_received {:hit, "/user/emails"}

      user = You.Repo.get_by(You.Accounts.User, email: "octo@example.com")
      assert user
      assert redirected_to(conn)
    end
  end
end
