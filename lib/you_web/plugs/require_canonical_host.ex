defmodule YouWeb.Plugs.RequireCanonicalHost do
  @moduledoc """
  Refuses a request that did not arrive on the canonical host with a 404
  naming the canonical issuer, rather than redirecting (#123).

  For the OAuth machine endpoints a POST is never safe to redirect: many
  clients downgrade a redirected POST to GET and drop the body, and most
  OAuth libraries do not follow redirects on a token request at all. A
  consumer landing here on an app host is misconfigured, and the useful
  response is an error naming where the real issuer is, not a redirect that
  fails in a way nobody watching the client library's logs can read.

  A no-op when `You.Hosting.enabled?/0` is false — see
  `YouWeb.Plugs.CanonicalHostRedirect`'s moduledoc for why this and
  app-host resolution share one gate.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if You.Hosting.enabled?() and not You.Hosting.canonical?(conn.host) do
      refuse(conn)
    else
      conn
    end
  end

  defp refuse(conn) do
    body =
      Jason.encode!(%{
        error: "invalid_request",
        error_description:
          "This endpoint is only served on the canonical issuer host: " <>
            You.Hosting.canonical_host()
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, body)
    |> halt()
  end
end
