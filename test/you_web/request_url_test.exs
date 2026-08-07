defmodule YouWeb.RequestURLTest do
  @moduledoc """
  Unit coverage for the allowlist itself, isolated from any particular
  route. `test/you_web/request_host_test.exs` covers the same guarantee
  end-to-end through the real mail-sending flows.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YouWeb.RequestURL

  # `YouWeb.Endpoint.host/0` reads a persistent_term the endpoint populates
  # on boot, so it can only be called once the app is running — a module
  # attribute would evaluate it at compile time and crash.
  defp canonical, do: YouWeb.Endpoint.host()

  # The refused-host log is rate-limited per host across the whole test run
  # (a shared ETS table, not reset per test case), so each test that expects
  # to see the log needs a host no earlier test has already tripped.
  defp unique_forged_host, do: "attacker-#{System.unique_integer([:positive])}.example.net"

  describe "allowed_hosts/0" do
    test "is exactly the canonical host today" do
      assert RequestURL.allowed_hosts() == [canonical()]
    end
  end

  describe "url/2" do
    test "keeps the canonical host as-is" do
      conn = %Plug.Conn{host: canonical()}
      assert URI.parse(RequestURL.url(conn, "/x")).host == canonical()
    end

    test "falls back to canonical for a host that isn't allowlisted, instead of raising" do
      conn = %Plug.Conn{host: unique_forged_host()}

      log =
        capture_log(fn ->
          assert URI.parse(RequestURL.url(conn, "/x")).host == canonical()
        end)

      assert log =~ "refused non-allowlisted request host"
    end

    test "accepts a LiveView socket's host_uri the same way" do
      allowed = %URI{host: canonical()}
      forged = %URI{host: unique_forged_host()}

      assert URI.parse(RequestURL.url(allowed, "/x")).host == canonical()
      assert URI.parse(RequestURL.url(forged, "/x")).host == canonical()
    end

    test "the path is preserved on both the allowed and the fallback path" do
      conn = %Plug.Conn{host: canonical()}
      assert RequestURL.url(conn, "/users/log-in/abc") =~ "/users/log-in/abc"

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
  end
end
