defmodule You.HostingTest do
  @moduledoc """
  `You.Hosting` is the one place that answers "is this request host one of
  You's own, and if so which app" (#121, #123) — `YouWeb.RequestURL`,
  `check_origin`, and `YouWeb.AuthMethods.app_for/1` all defer to it. These
  pin `resolve/1` itself, the single feature+template gate `enabled?/0`
  drives everything else through, and the canonical-collision guard the
  console write path relies on.
  """

  use You.DataCase, async: false

  alias You.Hosting

  defp enable_hostnames!(template \\ "{label}.example.com") do
    Application.put_env(:you, :app_hostname_template, template)
    You.Settings.set(:feature_app_hostnames, true)

    on_exit(fn ->
      You.Settings.set(:feature_app_hostnames, false)
      Application.delete_env(:you, :app_hostname_template)
    end)
  end

  defp create_app!(attrs) do
    {:ok, app, _secret} =
      You.Admin.create_app(
        Map.merge(
          %{
            slug: "app-#{System.unique_integer([:positive])}",
            name: "App",
            callback_url: "https://app-#{System.unique_integer([:positive])}.example.com/cb"
          },
          attrs
        )
      )

    app
  end

  describe "enabled?/0" do
    test "false with the feature off, even with a template set" do
      Application.put_env(:you, :app_hostname_template, "{label}.example.com")
      on_exit(fn -> Application.delete_env(:you, :app_hostname_template) end)

      refute Hosting.enabled?()
    end

    test "false with the feature on but no template" do
      You.Settings.set(:feature_app_hostnames, true)
      on_exit(fn -> You.Settings.set(:feature_app_hostnames, false) end)

      refute Hosting.enabled?()
    end

    test "false with the feature on and a template missing the {label} placeholder" do
      Application.put_env(:you, :app_hostname_template, "not-a-template.example.com")
      You.Settings.set(:feature_app_hostnames, true)

      on_exit(fn ->
        You.Settings.set(:feature_app_hostnames, false)
        Application.delete_env(:you, :app_hostname_template)
      end)

      refute Hosting.enabled?()
    end

    test "false with the feature on and a template naming {label} twice" do
      Application.put_env(:you, :app_hostname_template, "{label}.{label}.example.com")
      You.Settings.set(:feature_app_hostnames, true)

      on_exit(fn ->
        You.Settings.set(:feature_app_hostnames, false)
        Application.delete_env(:you, :app_hostname_template)
      end)

      refute Hosting.enabled?()
    end

    test "true with both configured" do
      enable_hostnames!()
      assert Hosting.enabled?()
    end
  end

  describe "resolve/1" do
    test "the canonical host resolves to :canonical even with the feature off" do
      assert Hosting.resolve(Hosting.canonical_host()) == :canonical
    end

    test "feature off: any other host is :unknown, never {:app, _}" do
      _app = create_app!(%{hostname_label: "acme"})
      refute Hosting.enabled?()

      assert Hosting.resolve("acme.example.com") == :unknown
    end

    test "feature on: a labelled app's rendered hostname resolves to it" do
      enable_hostnames!()
      app = create_app!(%{hostname_label: "acme"})

      assert {:app, resolved} = Hosting.resolve("acme.example.com")
      assert resolved.id == app.id
    end

    test "case and a trailing dot are normalized" do
      enable_hostnames!()
      app = create_app!(%{hostname_label: "acme"})

      assert {:app, resolved} = Hosting.resolve("ACME.example.com.")
      assert resolved.id == app.id
    end

    test "a host that doesn't match any label is :unknown, not an error" do
      enable_hostnames!()
      create_app!(%{hostname_label: "acme"})

      assert Hosting.resolve("nobody.example.com") == :unknown
    end

    test "a host that only partially matches the template is :unknown" do
      enable_hostnames!()
      create_app!(%{hostname_label: "acme"})

      assert Hosting.resolve("acme.example.org") == :unknown
      assert Hosting.resolve("acme.evil.example.com") == :unknown
    end

    # Real coverage of the ordering, not a restatement of the "feature off"
    # case above: a label is inserted *past* `App.changeset/2`'s write-time
    # collision guard (`AdminFixtures.insert_legacy_app!/1`, simulating a
    # label that became colliding after being accepted — a template set
    # later, or `PHX_HOST` renamed, per `label_collides_with_canonical?/1`'s
    # own moduledoc caveat that it is write-time only), then resolved
    # against a template that actually makes it collide. If `resolve/1`
    # checked app resolution before canonical, this would return
    # `{:app, _}` for the instance's own front door.
    test "canonical wins even when a real, stored label would otherwise collide" do
      # Empty prefix/suffix so the label can equal the canonical host
      # exactly, regardless of what `YouWeb.Endpoint.host/0` is here.
      enable_hostnames!("{label}")

      colliding_app =
        You.AdminFixtures.insert_legacy_app!("legacy-collider")
        |> Ecto.Changeset.change(hostname_label: Hosting.canonical_host())
        |> You.Repo.update!()

      assert Hosting.render_hostname(colliding_app.hostname_label) == Hosting.canonical_host()
      assert Hosting.resolve(Hosting.canonical_host()) == :canonical
    end
  end

  describe "own_host?/1 and canonical?/1" do
    test "own_host? is true for canonical and a resolved app, false otherwise" do
      enable_hostnames!()
      create_app!(%{hostname_label: "acme"})

      assert Hosting.own_host?(Hosting.canonical_host())
      assert Hosting.own_host?("acme.example.com")
      refute Hosting.own_host?("evil.example.net")
    end

    test "canonical? is true only for the canonical host" do
      enable_hostnames!()
      create_app!(%{hostname_label: "acme"})

      assert Hosting.canonical?(Hosting.canonical_host())
      refute Hosting.canonical?("acme.example.com")
    end
  end

  describe "hosts/0" do
    test "is exactly [canonical] with the feature off" do
      assert Hosting.hosts() == [Hosting.canonical_host()]
    end

    test "includes every labelled app's rendered hostname once enabled" do
      enable_hostnames!()
      create_app!(%{hostname_label: "acme"})
      create_app!(%{hostname_label: "beta"})
      create_app!(%{})

      hosts = Hosting.hosts()
      assert Hosting.canonical_host() in hosts
      assert "acme.example.com" in hosts
      assert "beta.example.com" in hosts
      assert length(hosts) == 3
    end

    # Must-fix: `RequestURL.allowed_hosts/0` and `resolve/1` have to agree
    # even when the template itself is typed with uppercase — `hosts/0`
    # renders through `render_hostname/1`, `resolve/1` matches through
    # `extract_label/3`, and both go through the same normalized
    # `split_template/0` now, so a mixed-case template can't make one
    # accept a host the other refuses.
    test "an uppercase template still agrees with resolve/1 and check_origin?/1" do
      enable_hostnames!("{label}.Example.COM")
      app = create_app!(%{hostname_label: "acme"})

      assert Hosting.hosts() == [Hosting.canonical_host(), "acme.example.com"]
      assert {:app, resolved} = Hosting.resolve("acme.example.com")
      assert resolved.id == app.id
      assert Hosting.check_origin?(URI.parse("http://acme.example.com"))
    end
  end

  describe "check_origin?/1" do
    test "accepts the canonical origin" do
      uri = URI.parse("http://" <> Hosting.canonical_host())
      assert Hosting.check_origin?(uri)
    end

    test "refuses an origin that is not one of You's own" do
      refute Hosting.check_origin?(URI.parse("http://evil.example.net"))
    end

    test "accepts a recognised app host once the feature is on" do
      enable_hostnames!()
      create_app!(%{hostname_label: "acme"})

      assert Hosting.check_origin?(URI.parse("http://acme.example.com"))
    end

    test "the same app host is refused before the feature is on" do
      create_app!(%{hostname_label: "acme"})
      refute Hosting.check_origin?(URI.parse("http://acme.example.com"))
    end

    # A scheme/port mismatch against a configured `:url` is deliberately not
    # exercised here: `YouWeb.Endpoint.config/1` reads from an ETS table
    # `Phoenix.Endpoint.Supervisor` populates at boot, not live from
    # `Application.get_env/2`, so flipping the application environment
    # mid-test would not actually change what `check_origin?/1` sees — it
    # would just make the test look like it covers something it doesn't.
    # `config/test.exs` leaves `:url` without a `:scheme`/`:port`, so that
    # branch's leniency (`is_nil(allowed) or ...`) is exercised by every
    # other test in this block instead.
  end

  describe "render_hostname/1 and label_collides_with_canonical?/1" do
    test "render_hostname splices the label into the template" do
      enable_hostnames!()
      assert Hosting.render_hostname("acme") == "acme.example.com"
    end

    test "render_hostname downcases a template typed with uppercase" do
      enable_hostnames!("{label}.Example.COM")
      assert Hosting.render_hostname("acme") == "acme.example.com"
    end

    test "render_hostname is nil with no template configured" do
      refute Hosting.render_hostname("acme")
    end

    test "render_hostname is nil with a malformed template (no placeholder)" do
      enable_hostnames!("not-a-template.example.com")
      refute Hosting.render_hostname("acme")
    end

    test "a label that would render to the canonical host collides" do
      # A degenerate but syntactically valid template (empty prefix and
      # suffix) so the collision can be constructed regardless of what
      # `YouWeb.Endpoint.host/0` happens to be in this environment, rather
      # than assuming it has a shape a template string can be built around.
      enable_hostnames!("{label}")

      assert Hosting.label_collides_with_canonical?(Hosting.canonical_host())
      refute Hosting.label_collides_with_canonical?("definitely-not-canonical")
    end

    test "the collision check is case-insensitive on both the label and the template" do
      enable_hostnames!("{label}")

      assert Hosting.label_collides_with_canonical?(String.upcase(Hosting.canonical_host()))
    end

    test "no template configured: nothing collides" do
      refute Hosting.label_collides_with_canonical?("anything")
    end
  end
end
