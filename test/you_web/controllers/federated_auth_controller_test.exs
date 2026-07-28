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
end
