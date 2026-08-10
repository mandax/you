defmodule YouWeb.Plugs.RateLimitTest do
  # async: false — the tests mutate the global rate-limit config, and ExUnit
  # runs sync modules only after all async ones, so no other test observes it.
  use YouWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias YouWeb.Plugs.RateLimit

  setup do
    original_limits = Application.get_env(:you, YouWeb.RateLimit)
    original_hops = Application.get_env(:you, :trusted_proxy_hops)
    original_debug = Application.get_env(:you, :trusted_proxy_hops_debug)

    on_exit(fn ->
      Application.put_env(:you, YouWeb.RateLimit, original_limits || %{})
      Application.put_env(:you, :trusted_proxy_hops_debug, original_debug || false)

      case original_hops do
        nil -> Application.delete_env(:you, :trusted_proxy_hops)
        hops -> Application.put_env(:you, :trusted_proxy_hops, hops)
      end
    end)

    :ok
  end

  defp limited(conn, key \\ :test_endpoint) do
    RateLimit.call(conn, RateLimit.init(key: key))
  end

  # `put_req_header/3` replaces any existing header of the same name, so
  # this appends directly to `req_headers` to simulate a request that
  # arrives with more than one X-Forwarded-For header line.
  defp add_forwarded_for_header(conn, value) do
    %{conn | req_headers: conn.req_headers ++ [{"x-forwarded-for", value}]}
  end

  test "passes requests through under the limit", %{conn: conn} do
    Application.put_env(:you, YouWeb.RateLimit, %{test_endpoint: {2, 60_000}})
    conn = %{conn | remote_ip: {203, 0, 113, 1}}

    refute limited(conn).halted
    refute limited(conn).halted
  end

  test "returns 429 with Retry-After once the limit is exceeded", %{conn: conn} do
    Application.put_env(:you, YouWeb.RateLimit, %{test_endpoint: {2, 60_000}})
    conn = %{conn | remote_ip: {203, 0, 113, 2}}

    limited(conn)
    limited(conn)
    conn = limited(conn)

    assert conn.halted
    assert conn.status == 429
    assert response(conn, 429) =~ "Too many requests"

    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) in 1..60
  end

  test "responds with JSON when the pipeline accepted JSON", %{conn: conn} do
    Application.put_env(:you, YouWeb.RateLimit, %{test_endpoint: {1, 60_000}})

    conn =
      %{conn | remote_ip: {203, 0, 113, 3}}
      |> put_private(:phoenix_format, "json")

    limited(conn)
    conn = limited(conn)

    assert conn.status == 429
    assert %{"error" => "rate_limited"} = json_response(conn, 429)
  end

  test "buckets are isolated per remote IP", %{conn: conn} do
    Application.put_env(:you, YouWeb.RateLimit, %{test_endpoint: {1, 60_000}})

    limited(%{conn | remote_ip: {203, 0, 113, 4}})

    refute limited(%{conn | remote_ip: {203, 0, 113, 5}}).halted
  end

  test "passes through when the key has no configured limit", %{conn: conn} do
    Application.put_env(:you, YouWeb.RateLimit, %{})

    refute limited(conn, :unconfigured).halted
  end

  describe "client IP resolution — no trusted proxy (default)" do
    setup do
      Application.delete_env(:you, :trusted_proxy_hops)
      Application.put_env(:you, YouWeb.RateLimit, %{test_endpoint: {1, 60_000}})
      :ok
    end

    # This is #141: with no proxy trusted, a client rotating the header on
    # every request must not earn a fresh bucket each time. Neutering the
    # fix (reading the header unconditionally, as the old code did) turns
    # this red.
    test "a rotating X-Forwarded-For does not evade the limit", %{conn: conn} do
      attempt = fn forged_ip ->
        conn
        |> add_forwarded_for_header(forged_ip)
        |> then(&%{&1 | remote_ip: {203, 0, 113, 20}})
        |> limited()
      end

      refute attempt.("198.51.100.1").halted

      assert attempt.("198.51.100.2").halted
      assert attempt.("198.51.100.3").halted
      assert attempt.("a-different-forged-value-every-time").halted
    end

    test "buckets are still isolated per remote_ip", %{conn: conn} do
      conn = add_forwarded_for_header(conn, "198.51.100.4")

      limited(%{conn | remote_ip: {203, 0, 113, 21}})

      refute limited(%{conn | remote_ip: {203, 0, 113, 22}}).halted
    end
  end

  describe "client IP resolution — trusted proxy hops configured" do
    setup do
      Application.put_env(:you, YouWeb.RateLimit, %{test_endpoint: {1, 60_000}})
      :ok
    end

    test "with 1 hop, the rightmost entry is the client — not the leftmost", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)

      attempt = fn header ->
        conn
        |> add_forwarded_for_header(header)
        |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})
        |> limited()
      end

      refute attempt.("attacker-forged, 198.51.100.5").halted
      # Same rightmost (trusted) entry, different forged prefix: still the
      # same bucket. Getting the direction backwards (leftmost) would pass
      # this because the two headers disagree there.
      assert attempt.("different-forgery, 198.51.100.5").halted
      # Different rightmost entry: a genuinely different client, own bucket.
      refute attempt.("attacker-forged, 198.51.100.6").halted
    end

    test "with 2 hops, the entry two from the right is taken, not the last one", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 2)

      attempt = fn header ->
        conn
        |> add_forwarded_for_header(header)
        |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})
        |> limited()
      end

      refute attempt.("A, 198.51.100.7, proxy1-internal-ip").halted
      # Rightmost entry ("proxy1-internal-ip") changes, but the trusted
      # 2nd-from-right entry the client actually is doesn't.
      assert attempt.("A, 198.51.100.7, another-proxy1-internal-ip").halted
      # The 2nd-from-right entry itself changes: genuinely a different client.
      refute attempt.("A, 198.51.100.8, proxy1-internal-ip").halted
    end

    # Two requests with an *identical* header prove only that some bucket
    # was chosen consistently — true of every resolution, including a
    # buggy one, since both land wherever that one choice sends them. Each
    # test below instead holds one position and varies another, so it can
    # only pass if the position that's supposed to matter is the one that
    # actually does.
    test "multiple X-Forwarded-For header lines are treated as one list", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)

      attempt = fn first_line, second_line ->
        conn
        |> add_forwarded_for_header(first_line)
        |> add_forwarded_for_header(second_line)
        |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})
        |> limited()
      end

      refute attempt.("attacker-forged", "198.51.100.9").halted
      # Second header line (rightmost, trusted) unchanged, first line
      # varies: same bucket. Reading only the first line would instead
      # make this the isolated case below.
      assert attempt.("different-forgery", "198.51.100.9").halted
      # Second header line changes: a genuinely different client, own
      # bucket — this is what "only the first line is read" would fail,
      # since that bug can never see this change at all.
      refute attempt.("attacker-forged", "198.51.100.10").halted
    end

    test "a chain shorter than the configured hops falls back to remote_ip", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 3)

      # A single *valid* IP — not a garbage string — so a pass here can only
      # be explained by the short-chain fallback, not the separate
      # unparseable-entry fallback below.
      attempt = fn remote_ip ->
        conn
        |> add_forwarded_for_header("198.51.100.12")
        |> then(&%{&1 | remote_ip: remote_ip})
        |> limited()
      end

      refute attempt.({203, 0, 113, 30}).halted
      assert attempt.({203, 0, 113, 30}).halted
      # Identical header, different remote_ip: if the fallback actually
      # falls back to remote_ip, this is a separate bucket. Clamping to the
      # header's one entry instead (ignoring how few there are) would put
      # both remote_ips in the same bucket, already over limit here.
      refute attempt.({203, 0, 113, 31}).halted
    end

    test "an entry that isn't an IP address falls back to remote_ip", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)

      attempt = fn remote_ip ->
        conn
        |> add_forwarded_for_header("unknown")
        |> then(&%{&1 | remote_ip: remote_ip})
        |> limited()
      end

      refute attempt.({203, 0, 113, 32}).halted
      assert attempt.({203, 0, 113, 32}).halted
      # Identical (garbage) header, different remote_ip: separate bucket
      # only if the fallback truly keys on remote_ip rather than on the
      # literal string "unknown".
      refute attempt.({203, 0, 113, 41}).halted
    end

    test "an empty X-Forwarded-For header falls back to remote_ip", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)
      conn = %{conn | remote_ip: {203, 0, 113, 33}}

      refute limited(conn).halted
      assert limited(conn).halted
    end

    test "accepts a bracketed IPv6 address with a port", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)

      attempt = fn header ->
        conn
        |> add_forwarded_for_header(header)
        |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})
        |> limited()
      end

      refute attempt.("[2001:db8::1]:443").halted
      assert attempt.("[2001:db8::1]:9999").halted
      refute attempt.("[2001:db8::2]:443").halted
    end

    test "accepts a bracketed IPv6 address with no port", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)

      attempt = fn header ->
        conn
        |> add_forwarded_for_header(header)
        |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})
        |> limited()
      end

      refute attempt.("[2001:db8::3]").halted
      # Same address, without brackets: strip_port/1 must resolve both to
      # the same parsed IP for this to share a bucket.
      assert attempt.("2001:db8::3").halted
      refute attempt.("[2001:db8::4]").halted
    end

    test "accepts a bare IPv6 address (no brackets, no port)", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)

      attempt = fn header ->
        conn
        |> add_forwarded_for_header(header)
        |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})
        |> limited()
      end

      refute attempt.("2001:db8::9").halted
      assert attempt.("2001:db8::9").halted
      refute attempt.("2001:db8::a").halted
    end

    test "accepts an IPv4 address with a port", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)

      attempt = fn header ->
        conn
        |> add_forwarded_for_header(header)
        |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})
        |> limited()
      end

      refute attempt.("198.51.100.11:8080").halted
      # Same address, no port: strip_port/1 must resolve both the same way.
      assert attempt.("198.51.100.11").halted
      refute attempt.("198.51.100.13:8080").halted
    end

    test "a large forged prefix never displaces the real (rightmost) entry", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)

      attempt = fn prefix, real_ip ->
        header = Enum.join(prefix, ",") <> "," <> real_ip

        conn
        |> add_forwarded_for_header(header)
        |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})
        |> limited()
      end

      prefix_a = Enum.map(1..500, &"forged-#{&1}")
      prefix_b = Enum.map(1..500, &"different-forged-#{&1}")

      refute attempt.(prefix_a, "7.7.7.20").halted
      # 500-entry forged prefix changes entirely, real (rightmost) entry
      # doesn't: same bucket. A left-anchored cap would drop the real entry
      # from the inspected window in both calls and fall back to
      # remote_ip — which also collides here, so this line alone wouldn't
      # catch that. The next line is what does.
      assert attempt.(prefix_b, "7.7.7.20").halted
      # Real entry changes, forged prefix doesn't: a genuinely different
      # client. A left-anchored cap would still be looking at forged
      # entries near the front and never notice — same (fallback) bucket,
      # still halted, and this assertion is what catches it.
      refute attempt.(prefix_a, "7.7.7.21").halted
    end

    # config/test.exs sets the global Logger level to :warning to keep the
    # suite quiet; capture_log's own :level option only filters within
    # whatever the global level already allows through (its docs say so
    # explicitly), so these two temporarily raise it to see the :info
    # message this feature actually logs at in dev/prod.
    test "TRUSTED_PROXY_HOPS_DEBUG logs the raw header and the resolved IP", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)
      Application.put_env(:you, :trusted_proxy_hops_debug, true)

      conn =
        conn
        |> add_forwarded_for_header("attacker-forged, 198.51.100.14")
        |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})

      original_level = Logger.level()
      Logger.configure(level: :info)
      log = capture_log(fn -> limited(conn) end)
      Logger.configure(level: original_level)

      assert log =~ "X-Forwarded-For="
      assert log =~ "attacker-forged, 198.51.100.14"
      assert log =~ "resolved=198.51.100.14"
    end

    test "logs nothing when TRUSTED_PROXY_HOPS_DEBUG is off", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)
      Application.put_env(:you, :trusted_proxy_hops_debug, false)

      conn =
        conn
        |> add_forwarded_for_header("198.51.100.15")
        |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})

      original_level = Logger.level()
      Logger.configure(level: :info)
      log = capture_log(fn -> limited(conn) end)
      Logger.configure(level: original_level)

      refute log =~ "X-Forwarded-For="
    end
  end

  describe "router integration" do
    test "POST /users/log-in is throttled after the configured attempts", %{conn: conn} do
      Application.put_env(:you, YouWeb.RateLimit, %{login: {2, 60_000}})

      conn = %{conn | remote_ip: {198, 51, 100, 7}}
      params = %{"user" => %{"email" => "nobody@example.com", "password" => "wrong password"}}

      post(conn, ~p"/users/log-in", params)
      post(conn, ~p"/users/log-in", params)
      conn = post(conn, ~p"/users/log-in", params)

      assert response(conn, 429) =~ "Too many requests"
      assert [_] = get_resp_header(conn, "retry-after")
    end

    test "GET routes on limited paths are not throttled", %{conn: conn} do
      Application.put_env(:you, YouWeb.RateLimit, %{login: {1, 60_000}})

      for _ <- 1..3 do
        assert html_response(get(conn, ~p"/users/log-in"), 200)
      end
    end

    # `GET /auth/:provider` (#132) writes a `federated_login_flows` row per
    # request and is reachable with no credential, so it's rate-limited like
    # every other unauthenticated write here — pipe_through is otherwise
    # untested (config/test.exs sets `%{}`, so nothing else in the suite
    # would catch it being dropped from the route).
    test "GET /auth/:provider is throttled after the configured attempts", %{conn: conn} do
      {:ok, _provider} =
        You.IdentityProviders.create_provider(%{
          "slug" => "google",
          "display_name" => "Google",
          "kind" => "google",
          "client_id" => "gid",
          "client_secret" => "gsecret",
          "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
          "token_url" => "https://oauth2.googleapis.com/token",
          "userinfo_url" => "https://openidconnect.googleapis.com/v1/userinfo",
          "scopes" => "openid email profile"
        })

      Application.put_env(:you, YouWeb.RateLimit, %{social_login: {2, 60_000}})
      conn = %{conn | remote_ip: {198, 51, 100, 8}}

      get(conn, ~p"/auth/google")
      get(conn, ~p"/auth/google")
      conn = get(conn, ~p"/auth/google")

      assert response(conn, 429) =~ "Too many requests"
      assert [_] = get_resp_header(conn, "retry-after")
    end
  end
end
