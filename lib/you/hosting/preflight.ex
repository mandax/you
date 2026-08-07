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
  reports which of five things is wrong, so an Admin with no shell access
  can name what to ask the Operator for instead of guessing:

  - `:invalid_label` — `label` is not a well-formed single DNS label
    (`You.Hostname.valid?/1`). Checked before anything else, including the
    template, and unconditionally — not something a caller can opt out of.
    `render_hostname/1` string-splices `label` into the template and the
    result becomes the authority of an outbound HTTPS request; a label
    carrying `/`, `@`, or `:` would relocate that request's host, port,
    userinfo or path (`localhost:4000/admin/`, `169.254.169.254/latest/
    meta-data/`, `user@attacker.example/`) — server-side request forgery
    reachable by whoever can call this with an arbitrary string. Callers on
    a trusted path (an app's own stored label) still pass this rejecting
    nothing real; it exists for callers that cannot make that guarantee,
    which is exactly what made the SSRF reachable in the first place.
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
  - `:wrong_traffic` — something answered, but it is not this instance:
    a non-3xx status other than 200, a 200 with a different issuer, or a
    redirect that does not land on this instance's own discovery
    document. Redirects are **not followed** (`redirect: false`) — anything
    that happens to 302 toward the real canonical discovery URL would
    otherwise report `:ok` without ever having been asked for by anyone
    but a parked domain or a catch-all vhost, which is exactly the failure
    this outcome exists to name.
  - `:ok` — resolves, negotiates TLS, and the response is either this
    instance's own `/.well-known/openid-configuration` (200, matching
    issuer) or a 3xx whose `location` **is** that same document — a
    stronger positive than the 200 case, since it proves the response came
    from this codebase's own `YouWeb.Plugs.CanonicalHostRedirect` rather
    than from anything that merely redirects somewhere plausible.

  DNS and HTTP are both bounded by a short timeout and never raise: a
  malformed response, a closed socket, an unexpected exception from the
  underlying libraries all fall into `:unreachable` rather than crashing
  the caller. The DNS resolver and HTTP client are swappable via
  `:you, :hosting_preflight_dns_resolver` / `:hosting_preflight_http_client`
  so tests can exercise every branch without touching the network.
  """

  alias You.Hosting

  # Worst-case hold time on the "Check" button, so it stays bounded and
  # worth stating rather than rediscovering: at most @dns_timeout, then at
  # most (connect + receive) @http_timeout twice over, since `redirect:
  # false` means `default_http_get/1` issues exactly one request — there is
  # no `max_redirects` multiplier to account for. ~13s worst case.
  @dns_timeout 3_000
  @http_timeout 5_000

  defstruct [:label, :host, :outcome, :detail]

  @type outcome ::
          :invalid_label
          | :template_invalid
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
    if You.Hostname.valid?(label) do
      check_template(label)
    else
      %__MODULE__{
        label: label,
        outcome: :invalid_label,
        detail: "Not a valid single DNS label — refused before any network call."
      }
    end
  end

  defp check_template(label) do
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

      {:ok, %{status: status, headers: headers}} when status in 300..399 ->
        classify_redirect(result, location_header(headers))

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
    if same_url?(issuer, YouWeb.Endpoint.url()) do
      %{result | outcome: :ok, detail: "Reached this instance (issuer #{issuer})."}
    else
      %{
        result
        | outcome: :wrong_traffic,
          detail: "Responded, but as a different issuer (#{inspect(issuer)}), not this instance."
      }
    end
  end

  defp classify_redirect(result, nil) do
    %{result | outcome: :wrong_traffic, detail: "Redirected, but with no Location header."}
  end

  defp classify_redirect(result, location) do
    if same_url?(location, canonical_discovery_url()) do
      %{
        result
        | outcome: :ok,
          detail: "Redirected to this instance's own canonical discovery document."
      }
    else
      %{
        result
        | outcome: :wrong_traffic,
          detail: "Redirected somewhere that isn't this instance's canonical host (#{location})."
      }
    end
  end

  defp canonical_discovery_url, do: YouWeb.Endpoint.url() <> "/.well-known/openid-configuration"

  defp location_header(headers) do
    case Map.get(headers, "location") do
      [location | _] -> location
      _ -> nil
    end
  end

  defp same_url?(a, b) when is_binary(a) and is_binary(b),
    do: normalize_url(a) == normalize_url(b)

  defp same_url?(_a, _b), do: false

  defp normalize_url(url) do
    url |> String.trim_trailing("/") |> String.downcase()
  end

  defp classify_error(result, reason) do
    if certificate_error?(reason) do
      %{
        result
        | outcome: :certificate_mismatch,
          detail: "TLS handshake failed: #{certificate_error_summary(reason)}"
      }
    else
      %{
        result
        | outcome: :unreachable,
          detail:
            "DNS resolves, but no response came back. This is also what a healthy instance " <>
              "sees checking its own hostname under hairpin routing — it is not proof of a " <>
              "real problem."
      }
    end
  end

  defp certificate_error?({:tls_alert, _}), do: true
  defp certificate_error?(%{reason: {:tls_alert, _}}), do: true
  defp certificate_error?(%{reason: {:bad_cert, _}}), do: true
  defp certificate_error?({:bad_cert, _}), do: true
  defp certificate_error?(_), do: false

  # One plain sentence, not `inspect/1` of the underlying term: a TLS alert
  # against a real mismatched certificate is a multi-hundred-character
  # nested tuple, and the reader here may have no shell to decode it — the
  # whole point of this panel is naming what to ask the Operator for, not
  # handing back a blob that does the opposite. `Logger` still gets the raw
  # term for whoever *can* read a stacktrace.
  defp certificate_error_summary(reason) do
    require Logger
    Logger.info("[Hosting.Preflight] TLS error detail: #{inspect(reason)}")
    tls_alert_summary(reason) || "the certificate presented does not verify for this hostname"
  end

  defp tls_alert_summary({:tls_alert, {alert, _msg}}), do: tls_alert_sentence(alert)
  defp tls_alert_summary(%{reason: {:tls_alert, {alert, _msg}}}), do: tls_alert_sentence(alert)
  defp tls_alert_summary(%{reason: {:bad_cert, reason}}), do: bad_cert_sentence(reason)
  defp tls_alert_summary({:bad_cert, reason}), do: bad_cert_sentence(reason)
  defp tls_alert_summary(_reason), do: nil

  defp tls_alert_sentence(:certificate_expired), do: "the certificate has expired"
  defp tls_alert_sentence(:certificate_unknown), do: "the certificate is not trusted"
  defp tls_alert_sentence(:unknown_ca), do: "the certificate's issuer is not trusted"
  defp tls_alert_sentence(:handshake_failure), do: "the TLS handshake failed"
  defp tls_alert_sentence(:bad_certificate), do: "the certificate is malformed or invalid"
  defp tls_alert_sentence(alert), do: "the TLS handshake failed (#{alert})"

  defp bad_cert_sentence(:hostname_check_failed),
    do: "the certificate does not cover this hostname"

  defp bad_cert_sentence(:cert_expired), do: "the certificate has expired"
  defp bad_cert_sentence(:selfsigned_peer), do: "the certificate is self-signed"
  defp bad_cert_sentence(:unknown_ca), do: "the certificate's issuer is not trusted"
  defp bad_cert_sentence(reason), do: "the certificate is invalid (#{reason})"

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

  # `redirect: false` is load-bearing, not an optimization: with Req's
  # default (`redirect: true, max_redirects: 10`), any server 302ing toward
  # the real canonical discovery URL — a parked domain, a catch-all vhost —
  # would be followed there and misreport `:ok`. `classify_redirect/2`
  # inspects the 3xx itself instead.
  defp default_http_get(url) do
    Req.get(url,
      receive_timeout: @http_timeout,
      connect_options: [timeout: @http_timeout],
      retry: false,
      redirect: false
    )
  rescue
    error -> {:error, error}
  end
end
