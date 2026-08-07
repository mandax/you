defmodule YouWeb.AuthMethodsTest do
  @moduledoc """
  Unit coverage for `app_for/2` and the `enabled?/2` app-struct clause added
  for #132: `FederatedAuthController` needs to resolve the app named by a
  `ctx` map (mint-time values that may not match this connection's own
  session) rather than always reading `conn`'s session directly. This pins
  that both give the same answer `app_for/1`/`enabled?/2` on a conn would.
  """

  use You.DataCase, async: true

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

  describe "enabled?/2 with an already-resolved app (not a conn)" do
    test "an app's own enabled_methods gates a resolved-app caller the same way it gates a conn" do
      app =
        create_app!(%{
          callback_url: "https://gated.example.com/cb",
          enabled_methods: ["password"]
        })

      refute AuthMethods.enabled?(app, "social")
      assert AuthMethods.enabled?(app, "password")
    end

    test "nil app (no app in flight) is unrestricted, same as app_for(conn) resolving nil" do
      assert AuthMethods.enabled?(nil, "social")
    end

    test "the instance-wide switch still beats an app that allows the method" do
      app =
        create_app!(%{callback_url: "https://switch.example.com/cb", enabled_methods: ["social"]})

      You.Settings.set(:feature_social_login, false)
      refute AuthMethods.enabled?(app, "social")
      You.Settings.set(:feature_social_login, true)
    end

    # Anything that isn't a conn, an %App{}, or nil is a caller bug — a
    # future #121 minter passing the wrong thing (a slug string, a map that
    # isn't a `ctx`) should get an immediate crash at the call site, not a
    # `FunctionClauseError` several frames deep inside `App.resolved_methods/2`.
    test "a value that is neither a conn, an App, nor nil raises immediately, at this boundary" do
      assert_raise FunctionClauseError, ~r/AuthMethods\.enabled\?\/2/, fn ->
        AuthMethods.enabled?("not-an-app", "social")
      end

      assert_raise FunctionClauseError, ~r/AuthMethods\.enabled_methods\/1/, fn ->
        AuthMethods.enabled_methods("not-an-app")
      end
    end
  end
end
