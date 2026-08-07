defmodule You.Hosting.Preflight do
  @moduledoc """
  A read-only, best-effort check of whether an app's hostname actually
  resolves and reaches this instance — run on demand from the Features
  panel (#127), never on mount and never gating `feature_app_hostnames`.

  Per-app hostnames need infrastructure outside You (a DNS record, a
  certificate) that only the Operator can provide, and `You.Hosting.
  enabled?/0` will happily report the feature on with a template that is
  missing or malformed. Both are reachable states whose only symptom,
  without this module, is that app hostnames silently never resolve. This
  reports which of four things is wrong, so an Admin with no shell access
  can name what to ask the Operator for instead of guessing:

  - `:template_invalid` — no `APP_HOSTNAME_TEMPLATE`, or one that is not
    exactly one `{label}` placeholder. Checked before any network call.
  - `:no_dns_record` — the rendered hostname does not resolve at all.
  - `:certificate_mismatch` — DNS resolves, but the TLS handshake fails
    (expired, wrong name, self-signed, etc).
  - `:unreachable` — DNS and TLS are not distinguishable as the problem,
    but no response came back (timeout, connection refused). **This is
    also what a healthy instance sees checking its own public hostname
    under hairpin routing** — a router or load balancer that cannot route
    a request back to the host that sent it. Reported, not treated as a
    failure the Operator needs to act on.
  - `:wrong_traffic` — something answered, but it is not this instance
    (wrong status, or a discovery document with a different issuer). DNS
    or a proxy is pointed somewhere else.
  - `:ok` — resolves, negotiates TLS, and the response is this instance's
    own `/.well-known/openid-configuration`.

  DNS and HTTP are both bounded by a short timeout and never raise: a
  malformed response, a closed socket, an unexpected exception from the
  underlying libraries all fall into `:unreachable` rather than crashing
  the caller. The DNS resolver and HTTP client are swappable via
  `:you, :hosting_preflight_dns_resolver` / `:hosting_preflight_http_client`
  so tests can exercise every branch without touching the network.
  """

  alias You.Hosting

  @dns_timeout 3_000
  @http_timeout 5_000

  defstruct [:label, :host, :outcome, :detail]

  @type outcome ::
          :template_invalid
          | :no_dns_record
          | :certificate_mismatch
          | :unreachable
          | :wrong_traffic
          | :ok

  @type t :: %__MODULE__{
          label: String.t() | nil,
          host: String.t() | nil,
          outcome: outcome(),
          detail: String.t() | nil
        }

  @doc """
  Runs the preflight for `label` synchronously. Callers on a request or
  LiveView path must wrap this in a task (see `YouWeb.ConsoleLive`'s
  `start_async/3` use) — it makes outbound network calls and is not fast.
  """
  @spec check(String.t()) :: t()
  def check(label) when is_binary(label) do
    if Hosting.template_valid?() do
      host = Hosting.render_hostname(label)
      check_dns(%__MODULE__{label: label, host: host})
    else
      %__MODULE__{
        label: label,
        outcome: :template_invalid,
        detail: "APP_HOSTNAME_TEMPLATE is not set, or is not exactly one {label} placeholder."
      }
    end
  end

  defp check_dns(%__MODULE__{host: host} = result) do
    case dns_resolver().(host) do
      :ok ->
        check_http(result)

      {:error, reason} ->
        %{result | outcome: :no_dns_record, detail: "DNS lookup failed: #{inspect(reason)}"}
    end
  end

  defp check_http(%__MODULE__{host: host} = result) do
    url = "https://#{host}/.well-known/openid-configuration"

    case http_client().(url) do
      {:ok, %{status: 200, body: %{"issuer" => issuer}}} ->
        classify_response(result, issuer)

      {:ok, %{status: status}} ->
        %{
          result
          | outcome: :wrong_traffic,
            detail: "Responded with HTTP #{status}, not this instance."
        }

      {:error, reason} ->
        classify_error(result, reason)
    end
  end

  defp classify_response(result, issuer) do
    if same_instance?(issuer) do
      %{result | outcome: :ok, detail: "Reached this instance (issuer #{issuer})."}
    else
      %{
        result
        | outcome: :wrong_traffic,
          detail: "Responded, but as a different issuer (#{inspect(issuer)}), not this instance."
      }
    end
  end

  defp same_instance?(issuer) when is_binary(issuer) do
    normalize_url(issuer) == normalize_url(YouWeb.Endpoint.url())
  end

  defp same_instance?(_issuer), do: false

  defp normalize_url(url) do
    url |> String.trim_trailing("/") |> String.downcase()
  end

  defp classify_error(result, reason) do
    if certificate_error?(reason) do
      %{
        result
        | outcome: :certificate_mismatch,
          detail: "TLS handshake failed: #{inspect(reason)}"
      }
    else
      %{
        result
        | outcome: :unreachable,
          detail:
            "DNS resolves, but no response came back (#{inspect(reason)}). This is also " <>
              "what a healthy instance sees checking its own hostname under hairpin " <>
              "routing — it is not proof of a real problem."
      }
    end
  end

  defp certificate_error?({:tls_alert, _}), do: true
  defp certificate_error?(%{reason: {:tls_alert, _}}), do: true
  defp certificate_error?(%{reason: {:bad_cert, _}}), do: true
  defp certificate_error?({:bad_cert, _}), do: true
  defp certificate_error?(_), do: false

  defp dns_resolver do
    Application.get_env(:you, :hosting_preflight_dns_resolver, &default_dns_lookup/1)
  end

  defp http_client do
    Application.get_env(:you, :hosting_preflight_http_client, &default_http_get/1)
  end

  defp default_dns_lookup(host) do
    case :inet_res.getbyname(String.to_charlist(host), :a, @dns_timeout) do
      {:ok, _hostent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp default_http_get(url) do
    Req.get(url,
      receive_timeout: @http_timeout,
      connect_options: [timeout: @http_timeout],
      retry: false
    )
  rescue
    error -> {:error, error}
  end
end
