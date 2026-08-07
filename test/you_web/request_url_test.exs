defmodule YouWeb.RequestURLTest do
  @moduledoc """
  Unit coverage for the allowlist itself, isolated from any particular
  route. `test/you_web/request_host_test.exs` covers the same guarantee
  end-to-end through the real mail-sending flows.
  """

  # `YouWeb.RequestURL.allowed_hosts/0` now delegates to `You.Hosting`
  # (#121), which reads `You.Settings` (feature flag, hostname template) and
  # the apps table — both DB-backed, so this needs the sandbox `ConnCase`
  # sets up. Plain `ExUnit.Case` was enough when the allowlist was a static
  # list.
  use YouWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias YouWeb.RequestURL

  # `YouWeb.Endpoint.host/0` reads a persistent_term the endpoint populates
  # on boot, so it can only be called once the app is running — a module
  # attribute would evaluate it at compile time and crash.
  defp canonical, do: YouWeb.Endpoint.host()

  # The refused-host log is rate-limited per host (hashed) across the whole
  # test run — a shared ETS table, not reset per test case — so each test
  # that expects to see the log needs a host no earlier test has already
  # tripped.
  defp unique_forged_host, do: "attacker-#{System.unique_integer([:positive])}.example.net"

  describe "allowed_hosts/0" do
    test "is exactly the canonical host with the feature off" do
      assert RequestURL.allowed_hosts() == [canonical()]
    end
  end

  # Must-fix from review: `allowed_hosts/0`'s delegation to `You.Hosting`
  # (#121) had zero coverage — neutering it back to a static
  # `[YouWeb.Endpoint.host()]` passed every test in this file. These prove
  # the delegation is real: an app's rendered hostname is in the allowlist,
  # *and* a link built for that host actually lands there rather than
  # falling back to canonical.
  describe "allowed_hosts/0 and url/2 with a recognised app host (#121)" do
    setup do
      Application.put_env(:you, :app_hostname_template, "{label}.example.com")
      You.Settings.set(:feature_app_hostnames, true)

      on_exit(fn ->
        You.Settings.set(:feature_app_hostnames, false)
        Application.delete_env(:you, :app_hostname_template)
      end)

      {:ok, app, _secret} =
        You.Admin.create_app(%{
          slug: "requrl-#{System.unique_integer([:positive])}",
          name: "App",
          callback_url: "https://requrl-#{System.unique_integer([:positive])}.example.com/cb",
          hostname_label: "requrl"
        })

      %{app_host: "requrl.example.com", app: app}
    end

    test "the app's rendered hostname is in allowed_hosts/0", %{app_host: app_host} do
      assert app_host in RequestURL.allowed_hosts()
    end

    test "a link built on the app host actually lands there, not on canonical", %{
      app_host: app_host
    } do
      conn = %Plug.Conn{host: app_host}

      log =
        capture_log(fn ->
          assert URI.parse(RequestURL.url(conn, "/x")).host == app_host
        end)

      assert log == ""
    end

    test "a host that merely resembles the pattern but names no app still falls back", %{} do
      conn = %Plug.Conn{host: "nobody.example.com"}

      log =
        capture_log(fn ->
          assert URI.parse(RequestURL.url(conn, "/x")).host == canonical()
        end)

      assert log =~ "refused non-allowlisted request host"
    end
  end

  describe "url/2 with an allowed host" do
    test "keeps the canonical host as-is, and logs nothing" do
      conn = %Plug.Conn{host: canonical()}

      log =
        capture_log(fn ->
          assert URI.parse(RequestURL.url(conn, "/x")).host == canonical()
        end)

      assert log == ""
    end

    test "matches case-insensitively" do
      conn = %Plug.Conn{host: String.upcase(canonical())}

      log =
        capture_log(fn ->
          assert URI.parse(RequestURL.url(conn, "/x")).host == canonical()
        end)

      assert log == ""
    end

    test "tolerates a single trailing dot (the DNS root label)" do
      conn = %Plug.Conn{host: canonical() <> "."}

      log =
        capture_log(fn ->
          assert URI.parse(RequestURL.url(conn, "/x")).host == canonical()
        end)

      assert log == ""
    end

    test "a LiveView socket's host_uri resolves the same way" do
      allowed = %URI{host: canonical()}

      log =
        capture_log(fn ->
          assert URI.parse(RequestURL.url(allowed, "/x")).host == canonical()
        end)

      assert log == ""
    end

    test "a live %Phoenix.LiveView.Socket{} is accepted directly, reading its own host_uri" do
      socket = %Phoenix.LiveView.Socket{host_uri: %URI{host: canonical()}}
      assert URI.parse(RequestURL.url(socket, "/x")).host == canonical()
    end

    test "a socket not mounted at the router falls back to canonical without raising" do
      socket = %Phoenix.LiveView.Socket{host_uri: :not_mounted_at_router}
      assert URI.parse(RequestURL.url(socket, "/x")).host == canonical()
    end
  end

  describe "url/2 with a host outside the allowlist" do
    test "falls back to canonical instead of raising, and logs the refusal" do
      host = unique_forged_host()
      conn = %Plug.Conn{host: host}

      log =
        capture_log(fn ->
          assert URI.parse(RequestURL.url(conn, "/x")).host == canonical()
        end)

      assert log =~ "refused non-allowlisted request host for link building"
    end

    test "the log line names the refused host and the canonical host, both inspected" do
      host = unique_forged_host()
      conn = %Plug.Conn{host: host}

      log =
        capture_log(fn ->
          RequestURL.url(conn, "/x")
        end)

      # `inspect/1`, not raw interpolation: a host holding control characters
      # or text shaped like a log line can't be mistaken for one.
      assert log =~ "request_host=#{inspect(host)}"
      assert log =~ "canonical_host=#{inspect(canonical())}"
    end

    test "a host that differs by more than case or a trailing dot is refused" do
      # `localhost:80` (a stray port) and a form with interior whitespace are
      # not normalized away — only case and a single trailing dot are.
      for host <- ["#{canonical()}:80", " #{canonical()}", "#{canonical()}.."] do
        conn = %Plug.Conn{host: host}

        log =
          capture_log(fn ->
            assert URI.parse(RequestURL.url(conn, "/x")).host == canonical()
          end)

        assert log =~ "refused non-allowlisted request host"
      end
    end

    test "the path is preserved on the fallback" do
      forged = %Plug.Conn{host: unique_forged_host()}

      log =
        capture_log(fn ->
          assert RequestURL.url(forged, "/users/log-in/abc") =~ "/users/log-in/abc"
        end)

      assert log =~ "refused non-allowlisted request host"
    end

    test "a refused host is logged at most once per rate-limit window" do
      forged = %Plug.Conn{host: unique_forged_host()}

      log =
        capture_log(fn ->
          for _ <- 1..5, do: RequestURL.url(forged, "/x")
        end)

      assert Enum.count(String.split(log, "refused non-allowlisted request host")) == 2
    end

    test "the rate-limit key is bounded regardless of host length" do
      # Bandit accepts a Host header up to ~9.9 KB with no charset
      # validation. If the limiter keyed on the raw host, an attacker
      # rotating long, distinct hosts would retain one unbounded ETS entry
      # per host for the rate-limit window. Keying on a hash instead means
      # the key size is constant no matter how long the forged host is.
      long_host = String.duplicate("a", 8_000) <> ".example.net"
      conn = %Plug.Conn{host: long_host}

      log =
        capture_log(fn ->
          assert URI.parse(RequestURL.url(conn, "/x")).host == canonical()
        end)

      assert log =~ "refused non-allowlisted request host"
      # The logged host itself is capped rather than reproducing all 8 KB.
      refute log =~ long_host
      assert log =~ "(truncated)"
    end

    # Worth-fixing from review: the per-host bucket bounds memory, not log
    # *volume* — 5000 distinct forged hosts in one window would otherwise
    # still be 5000 lines. There is a second, single-key bucket that caps
    # the total; setting its cap to 0 makes the very first hit in this
    # window exceed it regardless of what any other test already
    # contributed to the same shared bucket (`count >= 1 > 0` is deny no
    # matter the starting count), which is what makes this assertion
    # deterministic rather than dependent on suite ordering.
    test "a global cap suppresses logging even for a host whose own per-host bucket allows it" do
      Application.put_env(:you, :refused_host_log_global_cap, 0)
      on_exit(fn -> Application.delete_env(:you, :refused_host_log_global_cap) end)

      conn = %Plug.Conn{host: unique_forged_host()}

      log =
        capture_log(fn ->
          assert URI.parse(RequestURL.url(conn, "/x")).host == canonical()
        end)

      refute log =~ "refused non-allowlisted request host"
    end
  end
end
