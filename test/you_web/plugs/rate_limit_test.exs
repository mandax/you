defmodule YouWeb.Plugs.RateLimitTest do
  # async: false — the tests mutate the global rate-limit config, and ExUnit
  # runs sync modules only after all async ones, so no other test observes it.
  use YouWeb.ConnCase, async: false

  alias YouWeb.Plugs.RateLimit

  setup do
    original_limits = Application.get_env(:you, YouWeb.RateLimit)
    original_hops = Application.get_env(:you, :trusted_proxy_hops)

    on_exit(fn ->
      Application.put_env(:you, YouWeb.RateLimit, original_limits || %{})

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

    test "multiple X-Forwarded-For header lines are treated as one list", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)

      conn =
        conn
        |> add_forwarded_for_header("attacker-forged")
        |> add_forwarded_for_header("198.51.100.9")
        |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})

      refute limited(conn).halted
      assert limited(conn).halted
    end

    test "a chain shorter than the configured hops falls back to remote_ip", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 3)

      conn =
        conn
        |> add_forwarded_for_header("only-one-entry")
        |> then(&%{&1 | remote_ip: {203, 0, 113, 30}})

      refute limited(conn).halted
      assert limited(conn).halted

      other = %{conn | remote_ip: {203, 0, 113, 31}}
      refute limited(other).halted
    end

    test "an entry that isn't an IP address falls back to remote_ip", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 1)

      conn =
        conn
        |> add_forwarded_for_header("unknown")
        |> then(&%{&1 | remote_ip: {203, 0, 113, 32}})

      refute limited(conn).halted
      assert limited(conn).halted
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

    test "entries beyond the cap are never inspected", %{conn: conn} do
      Application.put_env(:you, :trusted_proxy_hops, 25)

      huge_prefix = Enum.map_join(1..1000, ",", fn n -> "forged-#{n}" end)

      conn =
        conn
        |> add_forwarded_for_header(huge_prefix <> ",198.51.100.10")
        |> then(&%{&1 | remote_ip: {203, 0, 113, 34}})

      # hops (25) exceeds the entries actually inspected (capped at 20), so
      # this falls back to remote_ip rather than hanging or crashing on an
      # attacker-sized header.
      refute limited(conn).halted
      assert limited(conn).halted
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
