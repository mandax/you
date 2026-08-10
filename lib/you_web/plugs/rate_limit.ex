defmodule YouWeb.Plugs.RateLimit do
  @moduledoc """
  Rate-limits credential-verifying endpoints with a fixed window per
  client IP.

      plug YouWeb.Plugs.RateLimit, key: :login

  Limits are read at request time so admins can tune them in
  `runtime.exs` without recompiling:

      config :you, YouWeb.RateLimit, %{login: {5, 60_000}}

  Keys without a configured limit pass through. When the limit is
  exceeded the request is halted with 429 and a `Retry-After` header.

  ## Client IP resolution

  `conn.remote_ip` is the TCP peer and cannot be spoofed, but behind a
  reverse proxy (the deployed shape — see docs/ops/deploy.md) it is the
  proxy's own address, not the caller's, so every request would share one
  bucket. `X-Forwarded-For` carries the real address instead, but a client
  can put anything it likes in a header, so it is trusted only as far as
  `TRUSTED_PROXY_HOPS` (`config/runtime.exs`, environment-only — see
  `You.Settings.forbidden_keys/0`) says: the number of proxies between this
  app and the internet that are known to append to, not rewrite, the
  header. It defaults to **0** — the header is ignored entirely and
  `remote_ip` is used — because trusting it by default is exactly the bug
  this module used to have (#141): a directly reachable instance, or one
  behind a proxy nobody has vouched for, must not let a client pick its own
  bucket.

  Each hop appends the address of whoever connected to it to the *right*
  end of the comma-separated list, so the rightmost entries are the ones
  this deployment's own infrastructure wrote and the leftmost is whatever
  the original caller sent (attacker-controlled). With `hops` configured,
  the client address is the entry `hops` positions from the right — the
  first thing the nearest trusted proxy appended — and everything to its
  left, forged prefix included, is discarded. Getting this backwards
  (taking the leftmost entry) is the classic mistake: it hands the bucket
  choice straight back to the client.

  Multiple `X-Forwarded-For` headers on one request are treated as one
  list, concatenated in the order they arrived. Entries are trimmed, IPv6
  addresses are accepted bracketed-with-port (`[::1]:443`) or bare, and
  only the rightmost entries are ever inspected, capped at 20 regardless of
  how long the header is — a client controls that length, and nothing
  beyond that many hops is a plausible chain. An entry that doesn't parse
  as an IP address (a blank field, `unknown`, garbage) or a chain shorter
  than `hops` falls back to `remote_ip` rather than trust something that
  isn't an address.

  `Forwarded` (RFC 7239) is deliberately not read: nothing in this stack's
  documented deployment shapes (Caddy, nginx, Traefik, a Cloudflare tunnel)
  emits it, and accepting a second, differently-shaped header for the same
  purpose would only widen what a forged request could try.
  """

  import Plug.Conn

  @behaviour Plug

  # An attacker controls X-Forwarded-For's length; nothing beyond this many
  # hops is a plausible proxy chain, so entries past it are never inspected.
  @max_forwarded_entries 20

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    key = Keyword.fetch!(opts, :key)

    case YouWeb.RateLimit.limit_for(key) do
      nil ->
        conn

      {limit, window_ms} ->
        bucket = {key, client_ip(conn)}
        enforce(conn, YouWeb.RateLimit.check(bucket, limit, window_ms))
    end
  end

  defp enforce(conn, {:allow, _count}), do: conn

  defp enforce(conn, {:deny, retry_after_ms}) do
    retry_after = max(ceil(retry_after_ms / 1_000), 1)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> respond()
    |> halt()
  end

  defp respond(conn) do
    if conn.private[:phoenix_format] == "json" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(429, "Too many requests. Please try again later.")
    end
  end

  defp client_ip(conn) do
    case trusted_proxy_hops() do
      0 -> remote_ip(conn)
      hops -> forwarded_client_ip(conn, hops) || remote_ip(conn)
    end
  end

  defp trusted_proxy_hops, do: Application.get_env(:you, :trusted_proxy_hops, 0)

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  # `with` here because every failure — no header, too few hops in the
  # chain, an entry that isn't an address — collapses to the same "can't
  # trust this" outcome and falls back to remote_ip in the caller.
  defp forwarded_client_ip(conn, hops) do
    with entries when entries != [] <- forwarded_entries(conn),
         {:ok, candidate} <- Enum.fetch(Enum.reverse(entries), hops - 1),
         {:ok, ip} <- candidate |> strip_port() |> to_charlist() |> :inet.parse_address() do
      ip |> :inet.ntoa() |> to_string()
    else
      _ -> nil
    end
  end

  # Every X-Forwarded-For header instance is one comma-separated list;
  # multiple instances on one request are treated as that one list,
  # concatenated in arrival order. Only the entries nearest the right edge
  # can ever matter (see moduledoc), so the list is trimmed to those before
  # anything else touches it.
  defp forwarded_entries(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> Enum.join(",")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-@max_forwarded_entries)
  end

  defp strip_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [addr, _port] -> addr
      [addr] -> addr
    end
  end

  # A single colon is an IPv4:port pair; more than one is a bare (portless)
  # IPv6 address, which proxies don't append a port to unbracketed.
  defp strip_port(entry) do
    case String.split(entry, ":") do
      [addr, _port] -> addr
      _no_port_or_ipv6 -> entry
    end
  end
end
