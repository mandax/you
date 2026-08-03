defmodule YouWeb.SEOController do
  @moduledoc """
  `robots.txt` and `sitemap.xml`.

  Both are rendered rather than served from `priv/static`, because both need to
  name absolute URLs and the host is only known at runtime: one image runs on
  any number of instances, each with its own `PHX_HOST`. A baked-in host would
  point every deployment's sitemap at somebody else's site.

  Only the public marketing page is listed. The account and console routes are
  behind authentication, and the OIDC/SCIM endpoints are for machines.
  """
  use YouWeb, :controller

  # Paths worth crawling, with how often they realistically change.
  @pages [{"/", "weekly", "1.0"}]

  # Authenticated or machine-facing surfaces. Listing them keeps crawlers from
  # spending the budget on pages that only ever answer 302 or 401.
  @disallowed ~w(/console /users /oauth /api /scim /.well-known)

  defp crawlable_pages do
    if You.Settings.enabled?(:feature_landing_page), do: @pages, else: []
  end

  def robots(conn, _params) do
    body = """
    User-agent: *
    #{Enum.map_join(@disallowed, "\n", &"Disallow: #{&1}")}

    Sitemap: #{url(~p"/sitemap.xml")}
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  def sitemap(conn, _params) do
    today = Date.utc_today() |> Date.to_iso8601()

    entries =
      Enum.map_join(crawlable_pages(), "\n", fn {path, changefreq, priority} ->
        """
          <url>
            <loc>#{YouWeb.Endpoint.url() <> path}</loc>
            <lastmod>#{today}</lastmod>
            <changefreq>#{changefreq}</changefreq>
            <priority>#{priority}</priority>
          </url>\
        """
      end)

    body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{entries}
    </urlset>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end
end
