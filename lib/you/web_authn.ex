defmodule You.WebAuthn do
  @moduledoc """
  The instance's WebAuthn relying-party ID, which request hosts may offer
  passkeys under it, and the origin check that lets them actually complete a
  ceremony.

  The RP ID itself is pinned once, at boot, by `WEBAUTHN_RP_ID`
  (`config/runtime.exs`) — environment-only, see `You.Settings.forbidden_keys/0`.
  Before it existed, `config :wax_, rp_id: :auto` derived the RP ID from the
  *configured* origin, resolved per challenge from that boot-fixed config
  (`URI.parse(origin).host`, never from the live request) — which is exactly
  `PHX_HOST`. That meant the RP ID moved whenever `PHX_HOST` did, silently:
  changing the public hostname an instance answers to also changed what
  every existing passkey was bound to, with nothing to say so. Pinning
  `WEBAUTHN_RP_ID` decouples the two — `PHX_HOST` can change without
  touching the RP ID — which is what makes per-app hostnames survivable at
  all: those hostnames are not the RP ID, and are only usable for passkeys
  where `available_for_host?/1` below says so. Changing `WEBAUTHN_RP_ID`
  itself is exactly as destructive as the old silent coupling was: every
  passkey registered under the old value stops matching, and, if you change
  it back, every one registered under the new value does too.

  Widening the RP ID to cover more hosts is deliberately not something this
  module offers: an RP ID that spans a zone also lets any other host in that
  zone request assertions for You's credentials, so the fix for a host that
  does not qualify is a hostname under the pinned RP ID, never a broader ID.
  """

  @doc "The relying-party ID `wax_` was configured with at boot."
  def rp_id, do: Application.fetch_env!(:wax_, :rp_id)

  @host_label ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/

  @doc """
  Whether `host` may offer passkeys under the configured RP ID.

  `demo.you.example.com` qualifies under RP ID `you.example.com` (it is the
  RP ID itself, extended with a subdomain label); `demo.example.com` does
  not (the RP ID is not a suffix of it at all). Comparison downcases both
  sides and tolerates one trailing dot (the DNS root label), matching
  `YouWeb.RequestURL`'s normalization for the same reason: a Host header a
  browser sends verbatim, uppercase or dotted, must not silently read as a
  non-match.

  `host` is also required to be a well-formed sequence of dot-separated
  labels (`[a-z0-9-]`, no empty label) — `.example.com` or `a..example.com`
  would otherwise satisfy a naive `String.ends_with?/2` suffix check without
  being a real hostname. `origin_matches?/2` below reuses this same
  predicate for the origin check, so this shape guard protects both.

  This is a plain suffix check, not the WebAuthn spec's full "registrable
  domain suffix" rule — it does not consult a public-suffix list, so nothing
  here stops `WEBAUTHN_RP_ID=co.uk` from being configured, and
  `origin_matches?/2` would then accept exactly as much as this function
  does since it delegates the host decision here. What actually refuses a
  public-suffix RP ID is the browser: it runs its own PSL-aware check before
  ever calling the WebAuthn API, so no page can complete a ceremony with
  such an RP ID regardless of what this predicate says. A wrong
  `WEBAUTHN_RP_ID` is a deployment bug either way — see
  `config/runtime.exs`'s boot-time check.
  """
  def available_for_host?(host) when is_binary(host) do
    rp = normalize(rp_id())
    host = normalize(host)
    valid_host?(host) and (host == rp or String.ends_with?(host, "." <> rp))
  end

  @doc """
  The `origin_verify_fun` MFA passed to `Wax.new_registration_challenge/1`
  and `Wax.new_authentication_challenge/1`.

  `Wax`'s default (`Wax.origins_match?/2`) is an exact match against the
  single configured `origin`, so it accepts the canonical host and refuses
  every subdomain outright — including ones `available_for_host?/1` says
  qualify. Routing both through this one predicate is what keeps the
  rendered gate and the actual cryptographic check from disagreeing: a host
  qualifies for passkeys, and can complete a ceremony, on exactly the same
  condition. Scheme and port must match the canonical origin exactly, and
  the client-supplied origin must be a bare `scheme://host[:port]` — no
  userinfo, path, query or fragment — before its host is even considered;
  only the host is allowed to vary, and only within the RP ID's zone.

  `client_data_origin` is attacker-controlled and untyped by the time it
  reaches here — `Wax.ClientData.parse_raw_json/1` assigns it straight from
  a JSON field with no check that it is even a string — so every clause here
  is written to return `false` rather than raise on it.
  """
  def origin_matches?(client_data_origin, challenge_origin)
      when is_binary(client_data_origin) do
    canonical = URI.parse(challenge_origin)

    case URI.parse(client_data_origin) do
      %URI{
        host: host,
        scheme: scheme,
        port: port,
        userinfo: nil,
        path: path,
        fragment: nil,
        query: nil
      }
      when is_binary(host) and path in [nil, "", "/"] ->
        scheme == canonical.scheme and port == canonical.port and available_for_host?(host)

      _ ->
        false
    end
  end

  def origin_matches?(_client_data_origin, _challenge_origin), do: false

  defp normalize(host) do
    host = String.downcase(host)
    if String.ends_with?(host, "."), do: binary_part(host, 0, byte_size(host) - 1), else: host
  end

  defp valid_host?(""), do: false
  defp valid_host?(host), do: host |> String.split(".") |> Enum.all?(&(&1 =~ @host_label))
end
