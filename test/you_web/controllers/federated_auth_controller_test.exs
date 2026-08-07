defmodule YouWeb.FederatedAuthControllerTest do
  use YouWeb.ConnCase, async: false

  alias You.IdentityProviders
  alias You.IdentityProviders.LoginFlow
  alias You.Repo

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

  # Drives the real `/auth/:provider` endpoint to mint a flow the way a
  # browser would, and returns `{conn, state}` — `conn` carries the binding
  # nonce cookie in its response, ready to be `recycle/1`d for a same-browser
  # callback.
  defp start_flow(conn, provider) do
    conn = get(conn, ~p"/auth/#{provider}")
    state = conn |> redirected_to(302) |> state_param()
    {conn, state}
  end

  defp state_param(location) do
    location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
  end

  # Stands up a local Bandit server as a stand-in for GitHub and registers a
  # github-kind provider pointed at it, so a full authorize→callback round
  # trip completes with no real network access — the only way this suite can
  # exercise what happens *after* `verify_state/3` succeeds. `email` becomes
  # the account's email, so callers minting more than one from the same test
  # get distinct users.
  defp github_mock!(port, email) do
    test_pid = self()

    plug = fn c, _opts ->
      send(test_pid, {:hit, c.request_path})

      body =
        case c.request_path do
          "/login/oauth/access_token" ->
            Jason.encode!(%{"access_token" => "gho_x"})

          "/user" ->
            Jason.encode!(%{"id" => port, "login" => "octo#{port}"})

          "/user/emails" ->
            Jason.encode!([%{"email" => email, "primary" => true, "verified" => true}])
        end

      c
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end

    server = start_supervised!({Bandit, plug: plug, port: port, ip: :loopback}, id: make_ref())
    on_exit(fn -> Process.unlink(server) end)
    base = "http://localhost:#{port}"

    original = Application.get_env(:you, :github_api_base_url)
    Application.put_env(:you, :github_api_base_url, base)
    on_exit(fn -> Application.put_env(:you, :github_api_base_url, original) end)

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

    :ok
  end

  defp attach_and_await_audit(fun) do
    test_pid = self()
    handler_id = "federated-audit-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:you, :audit, :login, :attempt],
      fn _event, _measurements, metadata, _config -> send(test_pid, {:audit_event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    fun.()

    assert_receive {:audit_event, metadata}, 1_000
    metadata
  end

  describe "GET /auth/:provider (authorize)" do
    test "reads the provider from the database, not app env", %{conn: conn} do
      create_provider!()

      conn = get(conn, ~p"/auth/google")

      assert redirected_to(conn, 302) =~ "accounts.google.com/o/oauth2/v2/auth"
      assert redirected_to(conn) =~ "client_id=gid"
    end

    test "sets a binding nonce cookie, HttpOnly and scoped to /auth", %{conn: conn} do
      create_provider!()

      conn = get(conn, ~p"/auth/google")

      cookie = conn.resp_cookies["_you_login_flow_nonce"]
      assert cookie
      assert cookie.http_only
      assert cookie.path == "/auth"
      assert is_binary(cookie.value) and cookie.value != ""
      # Pinned to the flow record's own expiry, not a second literal that
      # could drift from it — see `nonce_cookie_max_age_seconds/0`.
      assert cookie.max_age == LoginFlow.validity_in_minutes() * 60
    end

    # `Lax`, specifically: the callback arrives as a top-level cross-site GET
    # redirect *from the IdP*, so `Strict` would silently drop the cookie on
    # every real social login while every test here — which never leaves
    # this process — would still pass. Pin the value, not just its presence.
    test "the binding cookie is SameSite=Lax, not Strict", %{conn: conn} do
      create_provider!()

      conn = get(conn, ~p"/auth/google")

      assert conn.resp_cookies["_you_login_flow_nonce"].same_site == "Lax"
    end

    test "the binding cookie is Secure when the instance is, and not otherwise", %{conn: conn} do
      create_provider!()

      conn = get(conn, ~p"/auth/google")
      refute conn.resp_cookies["_you_login_flow_nonce"][:secure]

      original = Application.get_env(:you, :secure_cookies, false)
      Application.put_env(:you, :secure_cookies, true)
      on_exit(fn -> Application.put_env(:you, :secure_cookies, original) end)

      conn = get(build_conn(), ~p"/auth/google")
      assert conn.resp_cookies["_you_login_flow_nonce"][:secure]
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

  # Social is gated by the same two switches as every other method, and by the
  # per-app provider list on top. Turning the method off has to reject the
  # endpoint, not merely drop the button from the login page.
  describe "social as a gated sign-in method" do
    test "an app that omits \"social\" from enabled_methods is rejected", %{conn: conn} do
      create_provider!()

      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "no-social",
          name: "No Social",
          callback_url: "https://no-social.example.com/cb",
          enabled_methods: ["password", "magic_link"]
        })

      conn =
        conn
        |> init_test_session(callback_url: "https://no-social.example.com/cb")
        |> get(~p"/auth/google")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Unknown authentication provider."
    end

    test "an app that keeps \"social\" is allowed", %{conn: conn} do
      create_provider!()

      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "yes-social",
          name: "Yes Social",
          callback_url: "https://yes-social.example.com/cb",
          enabled_methods: ["password", "social"]
        })

      conn =
        conn
        |> init_test_session(callback_url: "https://yes-social.example.com/cb")
        |> get(~p"/auth/google")

      assert redirected_to(conn, 302) =~ "accounts.google.com"
    end

    test "the instance switch beats an app that allows social", %{conn: conn} do
      create_provider!()

      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "inst-social",
          name: "Inst Social",
          callback_url: "https://inst-social.example.com/cb",
          enabled_methods: ["password", "social"]
        })

      You.Settings.set(:feature_social_login, false)
      on_exit(fn -> You.Settings.set(:feature_social_login, true) end)

      conn =
        conn
        |> init_test_session(callback_url: "https://inst-social.example.com/cb")
        |> get(~p"/auth/google")

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "the instance switch also rejects a plain sign-in with no app in flight", %{conn: conn} do
      create_provider!()

      You.Settings.set(:feature_social_login, false)
      on_exit(fn -> You.Settings.set(:feature_social_login, true) end)

      conn = get(conn, ~p"/auth/google")

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "GET /auth/:provider/callback" do
    test "rejects an unknown provider slug without raising", %{conn: conn} do
      conn = get(conn, ~p"/auth/does-not-exist/callback", %{"code" => "x", "state" => "y"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Authentication failed."
    end

    # The provider allow-list is checked twice: at `/auth/:provider` (so a
    # disallowed provider is rejected before a flow record — and a network
    # round trip to the IdP — is even created) and again at the callback,
    # against the flow's own `ctx` rather than the session (#132 review).
    # That second check is what this test is for: an app's config can change
    # while the user is away at the IdP, and the callback has to catch it —
    # a check that only ran once, before the flow started, would let a
    # provider revoked mid-flight complete anyway.
    test "if an app's provider allow-list changes mid-flight, the callback still enforces it", %{
      conn: conn
    } do
      create_provider!()
      create_provider!(%{@google_attrs | "slug" => "github", "display_name" => "GitHub"})

      {:ok, app, _secret} =
        You.Admin.create_app(%{
          slug: "google-only",
          name: "Google Only",
          callback_url: "https://google-only.example.com/cb",
          # Unrestricted at mint time so the flow is legitimately started.
          enabled_providers: nil
        })

      {conn, state} =
        conn
        |> init_test_session(callback_url: "https://google-only.example.com/cb")
        |> start_flow("github")

      {:ok, _app} = You.Admin.update_app(app, %{enabled_providers: ["google"]})

      conn =
        conn
        |> recycle()
        |> init_test_session(callback_url: "https://google-only.example.com/cb")
        |> get(~p"/auth/github/callback", %{"code" => "x", "state" => state})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Authentication failed."

      # The nonce cookie is cleared on every failure branch, not only
      # state_mismatch: the flow it bound to is already spent (verify_state
      # consumed it single-use before this rejection), so the cookie is
      # stale regardless of which check downstream refused the login.
      assert conn.resp_cookies["_you_login_flow_nonce"].max_age == 0
    end
  end

  describe "state binding (#132): the callback only completes for the browser that started it" do
    test "a real flow, presented by the browser that started it, is accepted past state verification" do
      create_provider!()
      {conn, state} = start_flow(build_conn(), "google")

      # No provider configured for a real token exchange, so this still fails
      # further down the pipeline — but on a *network* error, not a state
      # mismatch, which is what proves `verify_state/3` let it through.
      conn =
        conn |> recycle() |> get(~p"/auth/google/callback", %{"code" => "x", "state" => state})

      refute Phoenix.Flash.get(conn.assigns.flash, :error) =~ "state mismatch"
    end

    test "consuming a flow deletes it: the state is unusable a second time" do
      create_provider!()
      {conn, state} = start_flow(build_conn(), "google")

      conn1 =
        conn |> recycle() |> get(~p"/auth/google/callback", %{"code" => "x", "state" => state})

      refute Phoenix.Flash.get(conn1.assigns.flash, :error) =~ "state mismatch"

      conn2 =
        conn |> recycle() |> get(~p"/auth/google/callback", %{"code" => "x", "state" => state})

      assert Phoenix.Flash.get(conn2.assigns.flash, :error) =~ "state mismatch"
    end

    test "a tampered state is refused" do
      create_provider!()
      {conn, state} = start_flow(build_conn(), "google")
      tampered = String.replace_prefix(state, String.first(state), "x")

      conn =
        conn |> recycle() |> get(~p"/auth/google/callback", %{"code" => "x", "state" => tampered})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "state mismatch"
    end

    test "an expired state is refused" do
      create_provider!()
      {conn, state} = start_flow(build_conn(), "google")

      past =
        DateTime.utc_now()
        |> DateTime.add(-(LoginFlow.validity_in_minutes() + 1) * 60, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(LoginFlow, set: [inserted_at: past])

      conn =
        conn |> recycle() |> get(~p"/auth/google/callback", %{"code" => "x", "state" => state})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "state mismatch"
    end

    test "a valid state with no binding cookie is refused" do
      create_provider!()

      # Minted directly through the context, bypassing `/auth/:provider`, so
      # this request never receives the nonce cookie — the state is
      # completely valid and unexpired, only the cookie is missing.
      {state, _nonce} =
        IdentityProviders.start_login_flow("google", %{
          "callback_url" => nil,
          "scopes" => nil,
          "code_challenge" => nil,
          "branding_app_slug" => nil,
          "state" => nil
        })

      conn = get(build_conn(), ~p"/auth/google/callback", %{"code" => "x", "state" => state})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "state mismatch"
    end

    test "a callback presented by a browser that did not initiate the flow is refused" do
      create_provider!()

      # The attacker's browser: runs /auth/:provider, captures `state` from
      # the redirect, but the resulting …/callback URL is never visited here
      # — it's handed to the victim instead. The attacker's nonce cookie
      # never leaves this cookie jar.
      {_attacker_conn, state} = start_flow(build_conn(), "google")

      # The victim's browser: a completely independent conn/cookie jar that
      # never ran /auth/:provider, clicking the captured link.
      victim_conn = build_conn()
      refute victim_conn.resp_cookies["_you_login_flow_nonce"]

      victim_conn =
        get(victim_conn, ~p"/auth/google/callback", %{"code" => "attacker-code", "state" => state})

      assert redirected_to(victim_conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(victim_conn.assigns.flash, :error) =~ "state mismatch"
    end

    test "a state mismatch emits the same audit event as any other failed login attempt" do
      create_provider!()
      {conn, state} = start_flow(build_conn(), "google")
      tampered = state <> "x"

      metadata =
        attach_and_await_audit(fn ->
          conn
          |> recycle()
          |> get(~p"/auth/google/callback", %{"code" => "x", "state" => tampered})
        end)

      assert metadata.method == "oidc:google"
      assert metadata.result == :failure
      assert metadata.reason == :state_mismatch
    end

    test "a missing-cookie refusal is just as observable as a state mismatch" do
      create_provider!()

      {state, _nonce} =
        IdentityProviders.start_login_flow("google", %{
          "callback_url" => nil,
          "scopes" => nil,
          "code_challenge" => nil,
          "branding_app_slug" => nil,
          "state" => nil
        })

      metadata =
        attach_and_await_audit(fn ->
          get(build_conn(), ~p"/auth/google/callback", %{"code" => "x", "state" => state})
        end)

      assert metadata.method == "oidc:google"
      assert metadata.result == :failure
      assert metadata.reason == :state_mismatch
    end
  end

  describe "?ctx= (groundwork for #121's cross-host handoff)" do
    test "a valid signed ctx is used instead of the session", %{conn: conn} do
      create_provider!()

      {:ok, app, _secret} =
        You.Admin.create_app(%{
          slug: "ctx-app",
          name: "Ctx App",
          callback_url: "https://ctx-app.example.com/cb"
        })

      signed =
        IdentityProviders.sign_ctx(%{
          "callback_url" => "https://ctx-app.example.com/cb",
          "scopes" => ["email"],
          "code_challenge" => "chal123",
          "branding_app_slug" => app.slug,
          "state" => "consumer-state-abc"
        })

      # No session at all: nothing for `ctx` to fall back to, so this only
      # passes if `ctx` itself is what's read.
      conn = get(conn, ~p"/auth/google?ctx=#{signed}")

      assert redirected_to(conn, 302) =~ "accounts.google.com"

      flow = Repo.one!(LoginFlow)
      assert LoginFlow.ctx(flow)["callback_url"] == "https://ctx-app.example.com/cb"
      assert LoginFlow.ctx(flow)["state"] == "consumer-state-abc"
    end

    test "an invalid ctx is refused outright, not fallen back to the (empty) session", %{
      conn: conn
    } do
      create_provider!()

      conn = get(conn, ~p"/auth/google?ctx=garbage")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"

      # The whole point of refusing outright rather than falling back: a
      # bogus `ctx` must not be a way to reach the weaker (no-ctx) path.
      # Nothing was minted and nothing was set for an attacker to work with.
      refute Repo.exists?(LoginFlow)
      refute conn.resp_cookies["_you_login_flow_nonce"]
    end

    test "a ctx naming an app that has disabled social is refused, not left to the session",
         %{conn: conn} do
      create_provider!()

      {:ok, app, _secret} =
        You.Admin.create_app(%{
          slug: "no-social-ctx",
          name: "No Social Ctx",
          callback_url: "https://no-social-ctx.example.com/cb",
          enabled_methods: ["password"]
        })

      signed =
        IdentityProviders.sign_ctx(%{
          "callback_url" => "https://no-social-ctx.example.com/cb",
          "scopes" => nil,
          "code_challenge" => nil,
          "branding_app_slug" => app.slug,
          "state" => nil
        })

      # No session naming any app — if the gate fell back to session-derived
      # `app_for/1` instead of resolving from `ctx`, this app's own
      # enabled_methods would never be consulted and the request would wrongly
      # go through.
      conn = get(conn, ~p"/auth/google?ctx=#{signed}")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Unknown authentication provider."
      refute Repo.exists?(LoginFlow)
    end
  end

  describe "github provider dispatch" do
    # GitHub has no userinfo endpoint and no `sub` claim, so a github-kind
    # provider must go through the adapter rather than the generic OIDC fetch.
    # The adapter's own behaviour is covered in identity_providers/github_test.
    # This is also the end-to-end proof that a real, same-browser flow
    # completes: it exercises `/auth/github` through the callback with the
    # actual nonce cookie the first request set.
    test "a github-kind provider routes through the adapter, not the OIDC userinfo fetch",
         %{conn: conn} do
      github_mock!(45_961, "octo@example.com")

      {conn, state} = start_flow(conn, "github")

      conn =
        conn
        |> recycle()
        |> get(~p"/auth/github/callback", %{"code" => "c", "state" => state})

      assert_received {:hit, "/login/oauth/access_token"}
      assert_received {:hit, "/user"}
      assert_received {:hit, "/user/emails"}

      user = You.Repo.get_by(You.Accounts.User, email: "octo@example.com")
      assert user
      assert redirected_to(conn)
    end
  end

  describe "restore_flow_session/2 (#132 review): ctx is the sole carrier of the handoff back to the consumer app" do
    # `redirect_with_code/4` reads `callback_url`/`scopes`/`code_challenge`/
    # `state` from the *session* — `restore_flow_session/2` is what puts them
    # there from the flow's `ctx` right before that runs. On canonical today
    # the incoming session already has the same values, so a no-op
    # `restore_flow_session/2` would still pass every other test in this
    # file. Proving it actually does something means starving the callback
    # request of session on purpose: recycling without re-seeding it, so the
    # only way this redirect can carry `callback_url` and `state` is through
    # `ctx`.
    test "a session-started flow: the consumer app gets its code and its own state back", %{
      conn: conn
    } do
      github_mock!(45_966, "session-ctx@example.com")

      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "session-consumer",
          name: "Session Consumer",
          callback_url: "https://session-consumer.example.com/cb"
        })

      conn =
        init_test_session(conn,
          callback_url: "https://session-consumer.example.com/cb",
          state: "consumer-state-session",
          scopes: ["email"]
        )

      {conn, state} = start_flow(conn, "github")

      # `recycle/1` alone would still carry the original session forward
      # (Plug re-signs the session cookie on every response once it's been
      # written to, callback response included), which would make this pass
      # even with a no-op `restore_flow_session/2` — exactly the false
      # positive under review. Poison the session on the recycled conn before
      # the callback so the only way to reach the right consumer/state is
      # through `restore_flow_session/2` overwriting it from `ctx`.
      conn =
        conn
        |> recycle()
        |> init_test_session(callback_url: nil, state: "WRONG-STATE", scopes: nil)
        |> get(~p"/auth/github/callback", %{"code" => "c", "state" => state})

      location = redirected_to(conn, 302)
      assert location =~ "https://session-consumer.example.com/cb"

      query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert query["state"] == "consumer-state-session"
      assert is_binary(query["code"]) and query["code"] != ""
    end

    test "a ctx-started flow, no session at all: the consumer app still gets its code and state",
         %{conn: conn} do
      github_mock!(45_967, "ctx-handoff@example.com")

      {:ok, _app, _secret} =
        You.Admin.create_app(%{
          slug: "ctx-consumer",
          name: "Ctx Consumer",
          callback_url: "https://ctx-consumer.example.com/cb"
        })

      signed =
        IdentityProviders.sign_ctx(%{
          "callback_url" => "https://ctx-consumer.example.com/cb",
          "scopes" => ["email"],
          "code_challenge" => nil,
          "branding_app_slug" => nil,
          "state" => "consumer-state-ctx"
        })

      conn = get(conn, ~p"/auth/github?ctx=#{signed}")
      state = conn |> redirected_to(302) |> state_param()

      conn =
        conn
        |> recycle()
        |> get(~p"/auth/github/callback", %{"code" => "c", "state" => state})

      location = redirected_to(conn, 302)
      assert location =~ "https://ctx-consumer.example.com/cb"

      query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert query["state"] == "consumer-state-ctx"
      assert is_binary(query["code"]) and query["code"] != ""
    end
  end
end
