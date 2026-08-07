defmodule YouWeb.RequestURL do
  @moduledoc """
  Absolute URLs built on the host a request or LiveView socket actually
  arrived on, instead of the instance-wide canonical host baked into
  `YouWeb.Endpoint`'s `:url` config.

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

  ## What must NOT go through here

  Two categories stay pinned to the canonical host on purpose, and reach for
  `YouWeb.Endpoint.url/0` (or a bare `url(~p"...")`, which resolves the same
  way) instead of this module:

    * The federated `redirect_uri` (`YouWeb.FederatedAuthController`) is
      registered with Google and GitHub against the canonical host; it can
      never follow the request host.
    * Machine endpoints — `iss`, JWKS, discovery, the token endpoint — whose
      host is a contract API consumers pin.

  Keeping those two off this module, rather than teaching it to special-case
  them, is deliberate: the next reader should not be able to move a machine
  endpoint onto a request host by threading one more argument through here.
  """

  @doc """
  Absolute URL for `path` (typically built with `~p`) on the host the
  request or LiveView socket arrived on, keeping the endpoint's configured
  scheme and port.

  Accepts a `%Plug.Conn{}` (controllers) or the `%URI{}` LiveView assigns as
  `socket.host_uri` on mount.
  """
  def url(conn_or_host_uri, path)

  def url(%Plug.Conn{host: host}, path) when is_binary(path), do: build(host, path)
  def url(%URI{host: host}, path) when is_binary(path), do: build(host, path)

  defp build(host, path) do
    YouWeb.Endpoint.struct_url()
    |> Map.put(:host, host)
    |> URI.to_string()
    |> Kernel.<>(path)
  end
end
