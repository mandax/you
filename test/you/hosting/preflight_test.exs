defmodule You.Hosting.PreflightTest do
  @moduledoc """
  `You.Hosting.Preflight.check/1` is what the Features panel (#127) runs on
  demand to tell an Admin, who may have no shell access, which of four
  things is wrong with an app's hostname: no DNS record, a certificate
  that doesn't cover it, traffic reaching something else, or a template
  that is missing or malformed. Every branch here is exercised end to end
  with a fake DNS resolver and HTTP client (`:you, :hosting_preflight_*`)
  rather than real network calls — real DNS/TLS failures aren't reliably
  reproducible in CI, and a test that skipped a branch here would be
  exactly the kind of vacuous test this project has shipped before.
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
