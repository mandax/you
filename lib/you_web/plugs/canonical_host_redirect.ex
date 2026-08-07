defmodule YouWeb.Plugs.CanonicalHostRedirect do
  @moduledoc """
  302s a GET request to the same path and query on the canonical host, when
  the request did not arrive on it (#123).

  For the two classes of route that must never answer on an app host at
  all: discovery/JWKS (there is exactly one issuer — serving discovery on an
  app host, even with `iss` correctly canonical, invites a consumer to
  configure the app host as its issuer and fail validation later) and
  `/console/*`/`/users/settings/*` (You's own admin and account surfaces,
  not an app's — reachable under a customer-branded hostname otherwise).

  A no-op when `You.Hosting.enabled?/0` is false: with per-app hostnames off
  or unconfigured there is no non-canonical host this instance recognises as
  its own to redirect *from*, and the redirect target is still derived from
  configuration (`You.Hosting.canonical_host/0`), never from the request —
  see `You.Hosting`'s moduledoc on why this and app-host resolution share
  one gate.

  302, not 301: these rules are expected to move while the feature settles,
  and a 301 is cached hard by browsers and intermediaries.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if You.Hosting.enabled?() and not You.Hosting.canonical?(conn.host) do
      redirect_to_canonical(conn)
    else
      conn
    end
  end

  defp redirect_to_canonical(conn) do
    target = canonical_url(conn)

    conn
    |> put_resp_header("location", target)
    |> send_resp(302, "")
    |> halt()
  end

  defp canonical_url(conn) do
    YouWeb.Endpoint.struct_url()
    |> Map.put(:host, You.Hosting.canonical_host())
    |> Map.put(:path, conn.request_path)
    |> URI.to_string()
    |> append_query(conn.query_string)
  end

  defp append_query(url, ""), do: url
  defp append_query(url, query), do: url <> "?" <> query
end
