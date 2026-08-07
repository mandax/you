defmodule YouWeb.Plugs.CanonicalHostRedirect do
  @moduledoc """
  302s a GET (or HEAD) request to the same path and query on the canonical
  host, when the request did not arrive on it (#123).

  For the two classes of route that must never answer on an app host at
  all: discovery/JWKS (there is exactly one issuer — serving discovery on an
  app host, even with `iss` correctly canonical, invites a consumer to
  configure the app host as its issuer and fail validation later) and
  `/console/*`/`/users/settings/*` (You's own admin and account surfaces,
  not an app's — reachable under a customer-branded hostname otherwise).

  Any other method (`PUT`, `DELETE`, the console's `POST /backup/export`)
  refuses with a 400 instead of redirecting — the same reasoning #123 gives
  for the OAuth machine endpoints in `RequireCanonicalHost` applies here
  too: a redirect silently drops the body of a non-GET request in most
  clients, so a mutation would either vanish or, worse, replay as a GET
  against a resource that doesn't expect one. `GET`/`HEAD` are the only
  methods `/console/*` and `/users/settings/*` actually expose as plain
  navigations; everything else on those paths is a form submission or an
  API call that has to fail loudly if it lands on the wrong host.

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

  @get_methods ["GET", "HEAD"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not You.Hosting.enabled?() -> conn
      You.Hosting.canonical?(conn.host) -> conn
      conn.method in @get_methods -> redirect_to_canonical(conn)
      true -> refuse_non_get(conn)
    end
  end

  defp redirect_to_canonical(conn) do
    target = canonical_url(conn)

    conn
    |> put_resp_header("location", target)
    |> send_resp(302, "")
    |> halt()
  end

  defp refuse_non_get(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(
      400,
      "This page is only served on the canonical host: #{You.Hosting.canonical_host()}"
    )
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
