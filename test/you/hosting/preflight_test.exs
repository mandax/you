defmodule You.Hosting.PreflightTest do
  @moduledoc """
  `You.Hosting.Preflight.check/1` is what the Features panel (#127) runs on
  demand to tell an Admin, who may have no shell access, which of several
  things is wrong with an app's hostname: an invalid label, no DNS record,
  a certificate that doesn't cover it, a redirect that lands somewhere
  other than this instance, traffic reaching something else outright, or a
  template that is missing or malformed. Every branch here is exercised
  end to end with a fake DNS resolver and HTTP client (`:you,
  :hosting_preflight_*`) rather than real network calls — real DNS/TLS
  failures aren't reliably reproducible in CI, and a test that skipped a
  branch here would be exactly the kind of vacuous test this project has
  shipped before.
  """

  use You.DataCase, async: false

  alias You.Hosting.Preflight

  setup do
    Application.put_env(:you, :app_hostname_template, "{label}.example.com")

    on_exit(fn ->
      Application.delete_env(:you, :app_hostname_template)
      Application.delete_env(:you, :hosting_preflight_dns_resolver)
      Application.delete_env(:you, :hosting_preflight_http_client)
    end)

    :ok
  end

  defp stub_dns(fun), do: Application.put_env(:you, :hosting_preflight_dns_resolver, fun)
  defp stub_http(fun), do: Application.put_env(:you, :hosting_preflight_http_client, fun)

  # `check/1` guards `label` itself, unconditionally, before the template or
  # any network call — not relying on the caller (`YouWeb.ConsoleLive`) to
  # have already resolved it against a real app. `render_hostname/1`
  # string-splices `label` into the template and the result becomes an
  # outbound request's authority; a label carrying `/`, `@`, or `:` would
  # relocate that request's host, port, userinfo or path entirely — SSRF
  # reachable by anyone who could call this module with an arbitrary
  # string, not only through the LiveView event this issue's review found
  # it through.
  describe "check/1 — label validation (SSRF guard)" do
    for crafted <- [
          "localhost:4000/admin/",
          "[::1]:22/",
          "169.254.169.254/latest/meta-data/",
          "user@attacker.example/",
          "acme.evil.example.com",
          ""
        ] do
      test "invalid_label for #{inspect(crafted)}, with no DNS or HTTP call" do
        stub_dns(fn _host -> raise "DNS must not be called for an invalid label" end)
        stub_http(fn _url -> raise "HTTP must not be called for an invalid label" end)

        result = Preflight.check(unquote(crafted))
        assert result.outcome == :invalid_label
      end
    end

    test "a real, well-formed label still runs the check" do
      stub_dns(fn _host -> {:error, :nxdomain} end)
      assert Preflight.check("acme").outcome == :no_dns_record
    end
  end

  describe "check/1 — template" do
    test "template_invalid when no template is configured, and never touches the network" do
      Application.delete_env(:you, :app_hostname_template)

      stub_dns(fn _host -> raise "DNS must not be called with no template" end)
      stub_http(fn _url -> raise "HTTP must not be called with no template" end)

      result = Preflight.check("acme")
      assert result.outcome == :template_invalid
    end

    test "template_invalid when the template is malformed" do
      Application.put_env(:you, :app_hostname_template, "not-a-template.example.com")
      stub_dns(fn _host -> raise "DNS must not be called with a malformed template" end)

      result = Preflight.check("acme")
      assert result.outcome == :template_invalid
    end
  end

  describe "check/1 — DNS" do
    test "no_dns_record when the resolver reports nxdomain, without an HTTP call" do
      stub_dns(fn _host -> {:error, :nxdomain} end)
      stub_http(fn _url -> raise "HTTP must not run after a DNS failure" end)

      result = Preflight.check("acme")
      assert result.outcome == :no_dns_record
      assert result.host == "acme.example.com"
    end
  end

  describe "check/1 — HTTP" do
    setup do
      stub_dns(fn _host -> :ok end)
      :ok
    end

    test "certificate_mismatch on a TLS alert" do
      stub_http(fn _url -> {:error, %{reason: {:tls_alert, {:handshake_failure, ~c"boom"}}}} end)

      assert Preflight.check("acme").outcome == :certificate_mismatch
    end

    test "unreachable on a connection timeout — worded as possibly hairpin, not a hard failure" do
      stub_http(fn _url -> {:error, %{reason: :timeout}} end)

      result = Preflight.check("acme")
      assert result.outcome == :unreachable
      assert result.detail =~ "hairpin"
    end

    test "wrong_traffic on a non-200 response" do
      stub_http(fn _url -> {:ok, %{status: 404, body: "not found"}} end)

      assert Preflight.check("acme").outcome == :wrong_traffic
    end

    test "wrong_traffic on a 200 with a different issuer" do
      stub_http(fn _url ->
        {:ok, %{status: 200, body: %{"issuer" => "https://someone-elses-instance.example"}}}
      end)

      assert Preflight.check("acme").outcome == :wrong_traffic
    end

    test "ok when the response is this instance's own discovery document" do
      stub_http(fn _url ->
        {:ok, %{status: 200, body: %{"issuer" => YouWeb.Endpoint.url()}}}
      end)

      result = Preflight.check("acme")
      assert result.outcome == :ok
    end

    # Neutered: if `check_http/1` matched the issuer with `==` on raw
    # strings instead of `same_instance?/1`'s trailing-slash/case
    # normalization, this would spuriously read as :wrong_traffic — pins
    # the normalization rather than merely the happy path above.
    test "ok is not defeated by a trailing slash or case difference in the issuer" do
      issuer = YouWeb.Endpoint.url() |> Kernel.<>("/") |> String.upcase()
      stub_http(fn _url -> {:ok, %{status: 200, body: %{"issuer" => issuer}}} end)

      assert Preflight.check("acme").outcome == :ok
    end

    test "a TLS alert's detail is a plain sentence, not a raw inspected term" do
      stub_http(fn _url ->
        {:error, %{reason: {:tls_alert, {:certificate_expired, ~c"boom"}}}}
      end)

      result = Preflight.check("acme")
      assert result.outcome == :certificate_mismatch
      assert result.detail =~ "certificate has expired"
      refute result.detail =~ "tls_alert"
      refute result.detail =~ "~c\""
    end
  end

  # Must-fix: with Req's own default (`redirect: true, max_redirects: 10`),
  # anything that happens to 302 toward the real canonical discovery URL —
  # a parked domain, a catch-all vhost — would be followed there and
  # misreport `:ok`, which is exactly the `:wrong_traffic` case this
  # outcome exists to catch. `redirect: false` plus `classify_redirect/2`
  # is what closes that; these tests would catch a regression back to
  # Req's default (or to trusting any 3xx as `:ok`) directly.
  describe "check/1 — redirects are not followed" do
    setup do
      stub_dns(fn _host -> :ok end)
      :ok
    end

    test "ok when a 302 lands exactly on this instance's own canonical discovery URL" do
      canonical = YouWeb.Endpoint.url() <> "/.well-known/openid-configuration"

      stub_http(fn _url ->
        {:ok, %{status: 302, headers: %{"location" => [canonical]}}}
      end)

      result = Preflight.check("acme")
      assert result.outcome == :ok
    end

    test "wrong_traffic when a 302 lands somewhere else entirely" do
      stub_http(fn _url ->
        {:ok, %{status: 302, headers: %{"location" => ["https://parked-domain.example/"]}}}
      end)

      result = Preflight.check("acme")
      assert result.outcome == :wrong_traffic
    end

    test "wrong_traffic when a 3xx carries no Location header at all" do
      stub_http(fn _url -> {:ok, %{status: 302, headers: %{}}} end)

      assert Preflight.check("acme").outcome == :wrong_traffic
    end
  end

  describe "check/1 result shape" do
    test "always returns the label and rendered host, whatever the outcome" do
      stub_dns(fn _host -> {:error, :nxdomain} end)

      result = Preflight.check("acme")
      assert result.label == "acme"
      assert result.host == "acme.example.com"
    end
  end
end
