defmodule YouWeb.AuthMethodsTest do
  @moduledoc """
  Unit coverage for the two ways a caller can ask what a request may use
  without holding a `Plug.Conn`.

  `app_for/2` exists for #132: `FederatedAuthController` resolves the app named
  by a `ctx` map — mint-time values that may not match this connection's own
  session — rather than always reading `conn`'s session. These pin that it
  gives the same answer `app_for/1` would on a conn.

  `enabled_methods/2` and `previewed_methods/1` are the #120 split: the first
  takes a real request host and gates passkeys on it, the second deliberately
  does not exist to skip that check but to describe an app independent of any
  host, for the settings preview.
  """

  # Settings are instance-wide, and several tests here flip them.
  use You.DataCase, async: false

  alias YouWeb.AuthMethods

  defp create_app!(attrs) do
    {:ok, app, _secret} =
      You.Admin.create_app(
        Map.merge(
          %{slug: "app-#{System.unique_integer([:positive])}", name: "App"},
          attrs
        )
      )

    app
  end

  describe "app_for/2" do
    test "resolves by callback_url, like app_for/1 does from the session" do
      app = create_app!(%{callback_url: "https://app.example.com/cb"})

      assert AuthMethods.app_for("https://app.example.com/cb", nil).id == app.id
    end

    test "falls back to branding_app_slug when callback_url names nothing" do
      app = create_app!(%{callback_url: "https://other.example.com/cb"})

      assert AuthMethods.app_for(nil, app.slug).id == app.id
      assert AuthMethods.app_for("https://unregistered.example.com/cb", app.slug).id == app.id
    end

    test "callback_url wins when both are given and name different apps" do
      by_callback = create_app!(%{callback_url: "https://by-callback.example.com/cb"})
      by_slug = create_app!(%{callback_url: "https://by-slug.example.com/cb"})

      resolved = AuthMethods.app_for("https://by-callback.example.com/cb", by_slug.slug)
      assert resolved.id == by_callback.id
    end

    test "neither given: no app" do
      refute AuthMethods.app_for(nil, nil)
      refute AuthMethods.app_for(nil, "")
    end
  end

  describe "enabled_methods/2 with an already-resolved app (not a conn)" do
    test "an app's own enabled_methods gates a resolved-app caller the same way it gates a conn" do
      app =
        create_app!(%{
          callback_url: "https://gated.example.com/cb",
          enabled_methods: ["password"]
        })

      refute "social" in AuthMethods.enabled_methods(app, "example.com")
      assert "password" in AuthMethods.enabled_methods(app, "example.com")
    end

    test "nil app (no app in flight) is unrestricted, same as app_for(conn) resolving nil" do
      assert "social" in AuthMethods.enabled_methods(nil, "example.com")
    end

    test "the instance-wide switch still beats an app that allows the method" do
      app =
        create_app!(%{callback_url: "https://switch.example.com/cb", enabled_methods: ["social"]})

      You.Settings.set(:feature_social_login, false)
      on_exit(fn -> You.Settings.set(:feature_social_login, true) end)

      refute "social" in AuthMethods.enabled_methods(app, "example.com")
    end

    # The guards on `enabled_methods/1,2` and `enabled?/2` are deliberately
    # not asserted here. Elixir 1.19's type checker rejects a wrongly-typed
    # literal at these call sites at *compile* time — a strictly stronger
    # guarantee than an `assert_raise` on the runtime clause, and one that
    # cannot be satisfied by a test that merely happens to pass. The guards
    # stay for the dynamic case (a future #121 minter threading a value the
    # checker cannot narrow), where they still fail at this boundary rather
    # than several frames deep inside `App.resolved_methods/2`.
  end

  # config/test.exs pins the WebAuthn RP ID to "example.com".
  describe "enabled_methods/2 (a real request host)" do
    test "includes passkey on a host under the configured RP ID" do
      assert "passkey" in AuthMethods.enabled_methods(nil, "demo.example.com")
    end

    test "omits passkey on a host outside the RP ID's zone" do
      refute "passkey" in AuthMethods.enabled_methods(nil, "example.org")
    end

    test "a disabled instance feature omits passkey even on a qualifying host" do
      You.Settings.set(:feature_passkeys, false)
      on_exit(fn -> You.Settings.set(:feature_passkeys, true) end)

      refute "passkey" in AuthMethods.enabled_methods(nil, "demo.example.com")
    end
  end

  # #121: app_for/1 gained a second precedence step (request-host
  # resolution) between callback_url and branding_app_slug. These pin the
  # order stated in its moduledoc and prove each step actually matters by
  # neutering the one ahead of it, not merely by asserting a value a fixture
  # happens to produce.
  describe "app_for/1 (a conn) — the three-way precedence" do
    setup do
      You.Settings.set(:hostname_template, "{label}.example.com")
      You.Settings.set(:feature_app_hostnames, true)

      on_exit(fn ->
        You.Settings.set(:feature_app_hostnames, false)
        You.Settings.set(:hostname_template, "")
      end)

      :ok
    end

    defp conn_with_session(host, session) do
      %Plug.Conn{host: host} |> Plug.Test.init_test_session(session)
    end

    test "host resolution names the app when nothing else does" do
      app =
        create_app!(%{hostname_label: "byhost", callback_url: "https://byhost.example.com/cb"})

      conn = conn_with_session("byhost.example.com", %{})

      assert AuthMethods.app_for(conn).id == app.id
    end

    test "callback_url beats a host that resolves to a different app" do
      by_callback = create_app!(%{callback_url: "https://precedence.example.com/cb"})

      by_host =
        create_app!(%{hostname_label: "byhost2", callback_url: "https://byhost2.example.com/cb"})

      conn =
        conn_with_session("byhost2.example.com", %{
          callback_url: "https://precedence.example.com/cb"
        })

      assert AuthMethods.app_for(conn).id == by_callback.id
      refute AuthMethods.app_for(conn).id == by_host.id
    end

    test "host resolution beats ?app= / branding_app_slug" do
      by_host =
        create_app!(%{hostname_label: "byhost3", callback_url: "https://byhost3.example.com/cb"})

      by_slug = create_app!(%{callback_url: "https://byslug.example.com/cb"})

      conn = conn_with_session("byhost3.example.com", %{branding_app_slug: by_slug.slug})

      assert AuthMethods.app_for(conn).id == by_host.id
    end

    test "an unrecognised host falls through to branding_app_slug, not to that host's absence of an app" do
      by_slug = create_app!(%{callback_url: "https://byslug2.example.com/cb"})
      conn = conn_with_session("nobody-owns-this.example.com", %{branding_app_slug: by_slug.slug})

      assert AuthMethods.app_for(conn).id == by_slug.id
    end

    test "feature off: host resolution never fires, even for a labelled app's own host" do
      _app =
        create_app!(%{hostname_label: "offhost", callback_url: "https://offhost.example.com/cb"})

      You.Settings.set(:feature_app_hostnames, false)

      conn = conn_with_session("offhost.example.com", %{})

      refute AuthMethods.app_for(conn)
    end
  end

  describe "previewed_methods/1 (no request host)" do
    test "includes passkey regardless of any host's RP ID qualification" do
      # There is no host-qualifying app in this scenario at all — the point
      # of previewed_methods/1 is that it never asks the question.
      assert "passkey" in AuthMethods.previewed_methods(nil)
    end

    test "a disabled instance feature still omits passkey" do
      You.Settings.set(:feature_passkeys, false)
      on_exit(fn -> You.Settings.set(:feature_passkeys, true) end)

      refute "passkey" in AuthMethods.previewed_methods(nil)
    end
  end
end
