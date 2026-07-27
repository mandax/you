defmodule YouWeb.SEOControllerTest do
  use YouWeb.ConnCase, async: true

  describe "GET /robots.txt" do
    test "allows crawling and points at the sitemap", %{conn: conn} do
      body = conn |> get(~p"/robots.txt") |> response(200)

      assert body =~ "User-agent: *"
      assert body =~ "Sitemap: #{YouWeb.Endpoint.url()}/sitemap.xml"
    end

    test "keeps crawlers out of authenticated and machine-facing paths", %{conn: conn} do
      body = conn |> get(~p"/robots.txt") |> response(200)

      for path <- ~w(/console /users /oauth /api /scim) do
        assert body =~ "Disallow: #{path}"
      end
    end

    test "is served as plain text", %{conn: conn} do
      conn = get(conn, ~p"/robots.txt")
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    end
  end

  describe "GET /sitemap.xml" do
    test "lists the landing page with an absolute URL", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)

      assert body =~ ~s(<?xml version="1.0" encoding="UTF-8"?>)
      assert body =~ "<loc>#{YouWeb.Endpoint.url()}/</loc>"
    end

    test "does not advertise authenticated routes", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)

      refute body =~ "/console"
      refute body =~ "/users"
    end

    test "is served as XML", %{conn: conn} do
      conn = get(conn, ~p"/sitemap.xml")
      assert get_resp_header(conn, "content-type") |> hd() =~ "xml"
    end
  end

  describe "landing page head" do
    test "carries a description, a canonical URL and structured data", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(<meta name="description")
      assert html =~ ~s(<link rel="canonical" href="#{YouWeb.Endpoint.url()}/")
      assert html =~ ~s(application/ld+json)
      # The JSON has to survive templating, not just be present.
      assert html =~ ~s("@type":"SoftwareApplication")
    end
  end
end
