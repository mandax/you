defmodule YouWeb.Plugs.ResolveAppHost do
  @moduledoc """
  Resolves `conn.host` to a registered app, once per request, ahead of the
  browser pipeline (#121).

  Assigns `:host_app` — the app the host resolves to, or `nil` for the
  canonical host or an unrecognised one. `YouWeb.AuthMethods.app_for/1`
  reads this assign when present rather than resolving again, so a page
  that calls it several times while rendering (the login page's `methods`
  and branding both do) triggers exactly one resolution, and exactly one
  unresolved-host log line, per request.

  A complete no-op when `You.Hosting.enabled?/0` is false — no resolution
  attempted, nothing assigned, nothing logged — which is what keeps the
  feature's "off, or template unset, is byte-identical to today" guarantee
  true here as much as everywhere else this milestone touches.

  ## Unresolved-host logging

  A request whose `Host` matches no app is not an error — it takes the
  fail-closed unbranded path, silently, from `AuthMethods.app_for/1`'s point
  of view. But it is also exactly the signature of someone pointing DNS at
  this instance to probe for an app to impersonate, and today it would leave
  no trace, so this is where that gets one: structured, and sampled the same
  way `YouWeb.RequestURL` samples its own refused-host log — one warning per
  `phash2` of the host per five-minute window, so a scripted probe against
  many forged hosts can't flood the log, and so the attacker-controlled host
  string itself never becomes an ETS key (see `YouWeb.RequestURL`'s
  moduledoc for the ~45 MB-per-5000-hosts retention that keying on the raw
  string caused the first time this rate-limit shape was written).

  A second, single-key bucket caps the *total* number of these lines per
  window, same as `YouWeb.RequestURL`'s: the per-host key alone bounds
  memory, not volume — 5000 distinct forged hosts in one window would
  otherwise still be 5000 log lines, one each, which is a log-flooding
  vector in its own right.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @refused_host_log_window :timer.minutes(5)
  # Overridable — see `YouWeb.RequestURL`'s matching constant for why.
  @refused_host_log_default_global_cap 200
  @max_logged_host_length 253

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if You.Hosting.enabled?() do
      resolve(conn)
    else
      conn
    end
  end

  defp resolve(conn) do
    case You.Hosting.resolve(conn.host) do
      {:app, app} ->
        assign(conn, :host_app, app)

      :canonical ->
        assign(conn, :host_app, nil)

      :unknown ->
        log_unresolved_host(conn.host)
        assign(conn, :host_app, nil)
    end
  end

  defp log_unresolved_host(host) do
    key = :erlang.phash2(host)

    with {:allow, 1} <-
           YouWeb.RateLimit.check({:unresolved_app_host, key}, 1, @refused_host_log_window),
         {:allow, _} <-
           YouWeb.RateLimit.check(
             :unresolved_app_host_global,
             global_log_cap(),
             @refused_host_log_window
           ) do
      Logger.warning(
        "unresolved app host: request_host=#{inspect(truncate(host))} " <>
          "canonical_host=#{inspect(You.Hosting.canonical_host())}"
      )
    else
      _ -> :ok
    end
  end

  defp global_log_cap,
    do:
      Application.get_env(
        :you,
        :unresolved_host_log_global_cap,
        @refused_host_log_default_global_cap
      )

  defp truncate(host) when byte_size(host) > @max_logged_host_length do
    binary_part(host, 0, @max_logged_host_length) <> "…(truncated)"
  end

  defp truncate(host), do: host
end
