defmodule YouWeb.UserSessionControllerTest do
  use YouWeb.ConnCase

  import You.AccountsFixtures
  alias You.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
  end

  describe "GET /users/log-in" do
    test "renders login page", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in")
      response = html_response(conn, 200)
      assert response =~ "Log in"
      assert response =~ ~p"/users/register"
      assert response =~ "Email me a magic link"
      # passkey sign-in entry point
      assert response =~ "Sign in with a passkey"
      assert response =~ ~p"/users/log-in/passkey/start"
    end

    test "shows a federated provider button only when configured", %{conn: conn} do
      refute get(conn, ~p"/users/log-in") |> html_response(200) =~ "Sign in with Google"

      {:ok, _provider} =
        You.IdentityProviders.create_provider(%{
          "slug" => "google",
          "display_name" => "Google",
          "kind" => "google"
        })

      html = get(conn, ~p"/users/log-in") |> html_response(200)
      assert html =~ "Sign in with Google"
      assert html =~ ~p"/auth/google"
    end

    test "omits a provider disabled for the in-flight app", %{conn: conn} do
      {:ok, _google} =
        You.IdentityProviders.create_provider(%{
          "slug" => "google",
          "display_name" => "Google",
          "kind" => "google"
        })

      {:ok, _github} =
        You.IdentityProviders.create_provider(%{
          "slug" => "github",
          "display_name" => "GitHub",
          "kind" => "generic"
        })

      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "google-only",
          name: "Google Only",
          callback_url: "https://google-only.example.com/cb",
          enabled_providers: ["google"]
        })

      html =
        conn
        |> get(~p"/users/log-in?callback_url=https://google-only.example.com/cb")
        |> html_response(200)

      assert html =~ "Sign in with Google"
      refute html =~ "Sign in with Github"
    end

    test "renders login page with email filled in (sudo mode)", %{conn: conn, user: user} do
      html =
        conn
        |> log_in_user(user)
        |> get(~p"/users/log-in")
        |> html_response(200)

      assert html =~ "Confirm your identity"
      refute html =~ "Sign up"
      assert html =~ "Email me a magic link"

      assert html =~
               ~s(<input type="hidden" name="user[email]" value="#{user.email}")
    end

    test "renders login page (email + password)", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in?mode=password")
      response = html_response(conn, 200)
      assert response =~ "Log in"
      assert response =~ ~p"/users/register"
      assert response =~ "Email me a magic link"
    end

    test "shows logo and brand color for a branded app's OAuth login", %{conn: conn} do
      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "branded",
          name: "Branded",
          callback_url: "https://branded.example.com/cb",
          logo_url: "https://branded.example.com/logo.png",
          brand_color: "#7c3aed"
        })

      html =
        conn
        |> get(~p"/users/log-in?callback_url=https://branded.example.com/cb")
        |> html_response(200)

      assert html =~ "Sign in to continue to"
      assert html =~ ~s(<img src="https://branded.example.com/logo.png")
      assert html =~ ~s(style="color: #7c3aed")
    end

    test "unbranded app gets the default login design", %{conn: conn} do
      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "plain",
          name: "Plain",
          callback_url: "https://plain.example.com/cb"
        })

      html =
        conn
        |> get(~p"/users/log-in?callback_url=https://plain.example.com/cb")
        |> html_response(200)

      assert html =~ "Sign in to continue to"
      assert html =~ ~s(<span class="text-primary">Plain</span>)
      assert html =~ "lucide-lock"
      refute html =~ "<img"
    end

    test "shows a custom headline and subtitle for an app's OAuth login", %{conn: conn} do
      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "custom-copy",
          name: "Custom Copy",
          callback_url: "https://custom-copy.example.com/cb",
          headline: "Welcome back to Custom Copy",
          subtitle: "please sign in to continue"
        })

      html =
        conn
        |> get(~p"/users/log-in?callback_url=https://custom-copy.example.com/cb")
        |> html_response(200)

      assert html =~ "Welcome back to Custom Copy"
      assert html =~ "please sign in to continue"
      refute html =~ "Sign in to continue to"
      refute html =~ "secured by You"
    end

    test "falls back to the default copy when headline/subtitle are unset", %{conn: conn} do
      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "default-copy",
          name: "Default Copy",
          callback_url: "https://default-copy.example.com/cb"
        })

      html =
        conn
        |> get(~p"/users/log-in?callback_url=https://default-copy.example.com/cb")
        |> html_response(200)

      assert html =~ "Sign in to continue to"
      assert html =~ ~s(<span class="text-primary">Default Copy</span>)
      assert html =~ "secured by You"
    end
  end

  describe "GET /users/log-in - authorize (consent screen)" do
    test "shows Terms of Service and Privacy Policy links when the app configures them", %{
      conn: conn,
      user: user
    } do
      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "consenting",
          name: "Consenting App",
          callback_url: "https://consenting.example.com/cb",
          tos_url: "https://consenting.example.com/tos",
          privacy_url: "https://consenting.example.com/privacy"
        })

      html =
        conn
        |> log_in_user(user)
        |> get(~p"/users/log-in?callback_url=https://consenting.example.com/cb&scope=email")
        |> html_response(200)

      assert html =~ "Authorize"
      assert html =~ ~s(href="https://consenting.example.com/tos")
      assert html =~ "Terms of Service"
      assert html =~ ~s(href="https://consenting.example.com/privacy")
      assert html =~ "Privacy Policy"
    end

    test "omits the consent links entirely when the app does not configure them", %{
      conn: conn,
      user: user
    } do
      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "unconsenting",
          name: "Unconsenting App",
          callback_url: "https://unconsenting.example.com/cb"
        })

      html =
        conn
        |> log_in_user(user)
        |> get(~p"/users/log-in?callback_url=https://unconsenting.example.com/cb&scope=email")
        |> html_response(200)

      assert html =~ "Authorize"
      refute html =~ "Terms of Service"
      refute html =~ "Privacy Policy"
      refute html =~ "By continuing, you agree to"
    end
  end

  describe "per-app auth method toggles" do
    setup do
      {:ok, app, _secret} =
        You.Admin.create_app(%{
          slug: "gated",
          name: "Gated",
          callback_url: "https://gated.example.com/cb",
          enabled_methods: ["passkey"]
        })

      %{app: app}
    end

    defp start_flow(conn, app) do
      get(conn, ~p"/users/log-in?callback_url=#{app.callback_url}")
    end

    test "the login page omits controls for disabled methods", %{conn: conn, app: app} do
      html = conn |> start_flow(app) |> html_response(200)

      refute html =~ ~s(id="login_form_password")
      refute html =~ ~s(id="login_form_magic")
      assert html =~ ~s(id="passkey-login")
    end

    # Hiding the form is not the feature. Anyone can POST directly, so the
    # rejection below is what actually disables the method.
    test "a password POST is rejected for an app that disabled it", %{conn: conn, app: app} do
      user = You.AccountsFixtures.user_fixture()

      conn =
        conn
        |> start_flow(app)
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "hello world!"}
        })

      assert redirected_to(conn) =~ "/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not available"
      refute get_session(conn, :user_token)
    end

    test "a magic-link request is rejected for an app that disabled it", %{conn: conn, app: app} do
      user = You.AccountsFixtures.user_fixture()

      conn =
        conn
        |> start_flow(app)
        |> post(~p"/users/log-in", %{"user" => %{"email" => user.email}})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not available"
    end

    test "nil enabled_methods leaves every method working", %{conn: conn} do
      {:ok, open_app, _} =
        You.Admin.create_app(%{
          slug: "open",
          name: "Open",
          callback_url: "https://open.example.com/cb"
        })

      assert open_app.enabled_methods == nil

      html = conn |> start_flow(open_app) |> html_response(200)

      assert html =~ ~s(id="login_form_password")
      assert html =~ ~s(id="login_form_magic")
    end

    test "a plain login with no app in flight keeps every method", %{conn: conn} do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ ~s(id="login_form_password")
      assert html =~ ~s(id="login_form_magic")
    end
  end

  describe "GET /users/log-in/:token" do
    test "renders confirmation page for unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      conn = get(conn, ~p"/users/log-in/#{token}")
      assert html_response(conn, 200) =~ "Confirm and stay logged in"
    end

    test "renders login page for confirmed user", %{conn: conn, user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      conn = get(conn, ~p"/users/log-in/#{token}")
      html = html_response(conn, 200)
      refute html =~ "Confirm my account"
      assert html =~ "Log in"
    end

    test "raises error for invalid token", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in/invalid-token")
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Magic link is invalid or it has expired."
    end
  end

  describe "POST /users/log-in - email and password" do
    test "logs the user in", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/dashboard"

      # Now do a logged in request and assert on the dashboard nav
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ "Dashboard"
      assert response =~ ~p"/users/dashboard"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_you_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/users/dashboard"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "emits error message with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      response = html_response(conn, 200)
      assert response =~ "Log in"
      assert response =~ "Invalid email or password"
    end

    test "OAuth callback redirect carries code and echoes state", %{conn: conn, user: user} do
      user = set_password(user)

      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "myapp",
          name: "Myapp",
          callback_url: "https://myapp.example.com/auth/callback"
        })

      conn =
        conn
        |> init_test_session(
          callback_url: "https://myapp.example.com/auth/callback",
          scopes: ["email"],
          state: "opaque-xyz"
        )
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      location = redirected_to(conn)
      assert location =~ "https://myapp.example.com/auth/callback?"
      assert location =~ "code="
      assert location =~ "state=opaque-xyz"
    end
  end

  describe "POST /users/log-in - magic link" do
    test "sends magic link email when user exists", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
      assert You.Repo.get_by!(Accounts.UserToken, user_id: user.id).context == "login"
    end

    test "logs the user in", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/dashboard"

      # Now do a logged in request and assert on the dashboard nav
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ "Dashboard"
      assert response =~ ~p"/users/dashboard"
    end

    test "confirms unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      refute user.confirmed_at

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "User confirmed successfully."

      assert Accounts.get_user!(user.id).confirmed_at

      # Now do a logged in request and assert on the dashboard nav
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ "Dashboard"
      assert response =~ ~p"/users/dashboard"
    end

    test "emits error message when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => "invalid"}
        })

      assert html_response(conn, 200) =~ "The link is invalid or it has expired."
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
