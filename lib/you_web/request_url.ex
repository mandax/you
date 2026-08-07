defmodule YouWeb.RequestURL do
  @moduledoc """
  Absolute URLs built on the host a request or LiveView socket actually
  arrived on, instead of the instance-wide canonical host baked into
  `YouWeb.Endpoint`'s `:url` config — but only when that host is one You
  already knows about.

  Every link You emails a user to click — magic link, confirmation, password
  reset, email change, invitation — has to round-trip to the host the flow
  started on. Sessions are host-local: a link that lands on a different host
  opens a different session, not merely a differently branded page, so a
  bare `url(~p"...")` (which always resolves against the static canonical
  host) is the wrong tool for these. Callers that build one of these links
  use `url/2` here instead, passing the `conn` or LiveView `socket` the flow
  is running on.

  Today an instance has exactly one host (`PHX_HOST`), so this changes
  nothing observable yet — it is the plumbing for per-app hostnames, landing
  separately. Once an app has its own hostname, a flow that started on
  `acme.example.com` builds links back to `acme.example.com` rather than the
  canonical host.

  ## Host allowlist

  `conn.host` (and a LiveView socket's `host_uri.host`) come straight off the
  `Host` header, which a client fully controls. Using it to build a link
  unconditionally is host-header injection: request a password reset or
  magic link for a victim's address with a forged `Host`, and a live
  credential — for the magic link, a full authentication token, not merely a
  reset step — is emailed pointing at a host the attacker controls.

  So a request host is only ever used if it is in `allowed_hosts/0` — never
  because it arrived in a header. Today that set is exactly the canonical
  host, so this doesn't change what today's emails link to. #121 (per-app
  hostnames) is meant to extend `allowed_hosts/0` with hosts that resolve to
  a known app through *configuration* — a value You controls, such as an
  app's configured hostname column — never by trusting the header alone.
  That is the same rule #121 states for its own host-based app resolution;
  the two must agree, or one of them is the hole the other closed. A host
  outside the allowlist silently falls back to canonical rather than
  raising: a forged header must not be able to turn into a 500 an attacker
  can trigger at will.
  """

  require Logger

  @doc """
  Absolute URL for `path` (typically built with `~p`) on the host the
  request or LiveView socket arrived on, when that host is allowed, or on
  the canonical host otherwise.

  Accepts a `%Plug.Conn{}` (controllers) or the `%URI{}` LiveView assigns as
  `socket.host_uri` on mount.
  """
  def url(conn_or_host_uri, path)

  def url(%Plug.Conn{host: host}, path) when is_binary(path), do: build(host, path)
  def url(%URI{host: host}, path) when is_binary(path), do: build(host, path)

  @doc """
  The hosts a request-built link is allowed to point at. Exactly the
  canonical host today. #121 extends this list with hosts that resolve to a
  configured app — it must not become a pass-through for whatever arrived
  on the request.
  """
  def allowed_hosts, do: [YouWeb.Endpoint.host()]

  defp build(host, path) do
    YouWeb.Endpoint.struct_url()
    |> Map.put(:host, resolve_host(host))
    |> URI.to_string()
    |> Kernel.<>(path)
  end

  defp resolve_host(host) do
    if host in allowed_hosts() do
      host
    else
      log_refused_host(host)
      YouWeb.Endpoint.host()
    end
  end

  # A Host header that doesn't resolve to a known host, hitting a route that
  # emails a link, is the signature of someone probing for exactly the
  # injection this module exists to close. Sampled to one log line per host
  # per window rather than one per request, so a scripted probe against many
  # forged hosts can't be used to flood the log.
  defp log_refused_host(host) do
    case YouWeb.RateLimit.check({:refused_request_host, host}, 1, :timer.minutes(5)) do
      {:allow, 1} ->
        Logger.warning("refused non-allowlisted request host for link building",
          request_host: host,
          canonical_host: YouWeb.Endpoint.host()
        )

      _ ->
        :ok
    end
  end
end
