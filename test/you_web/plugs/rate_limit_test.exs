defmodule YouWeb.Plugs.RateLimitTest do
  # async: false — the tests mutate the global rate-limit config, and ExUnit
  # runs sync modules only after all async ones, so no other test observes it.
  use YouWeb.ConnCase, async: false

  alias YouWeb.Plugs.RateLimit

  setup do
    original = Application.get_env(:you, YouWeb.RateLimit)
    on_exit(fn -> Application.put_env(:you, YouWeb.RateLimit, original || %{}) end)
    :ok
  end

  defp limited(conn, key \\ :test_endpoint) do
    RateLimit.call(conn, RateLimit.init(key: key))
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

  test "X-Forwarded-For takes precedence over remote_ip", %{conn: conn} do
    Application.put_env(:you, YouWeb.RateLimit, %{test_endpoint: {1, 60_000}})

    proxied = fn ip ->
      conn
      |> put_req_header("x-forwarded-for", ip)
      |> then(&%{&1 | remote_ip: {10, 0, 0, 1}})
      |> limited()
    end

    proxied.("198.51.100.9")

    assert proxied.("198.51.100.9").halted
    refute proxied.("198.51.100.10").halted
  end

  test "passes through when the key has no configured limit", %{conn: conn} do
    Application.put_env(:you, YouWeb.RateLimit, %{})

    refute limited(conn, :unconfigured).halted
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
  end
end
