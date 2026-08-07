defmodule You.WebAuthn do
  @moduledoc """
  The instance's WebAuthn relying-party ID, which request hosts may offer
  passkeys under it, and the origin check that lets them actually complete a
  ceremony.

  The RP ID itself is pinned once, at boot, by `WEBAUTHN_RP_ID`
  (`config/runtime.exs`) — environment-only, see `You.Settings.forbidden_keys/0`.
  Before it existed, `config :wax_, rp_id: :auto` derived the RP ID from the
  *configured* origin (`URI.parse(origin).host`, resolved once at challenge
  creation — never per request), which is exactly `PHX_HOST`. That meant the
  RP ID moved whenever `PHX_HOST` did, silently: changing the public
  hostname an instance answers to also changed what every existing passkey
  was bound to, with nothing to say so. Pinning `WEBAUTHN_RP_ID` decouples
  the two — `PHX_HOST` can change without touching the RP ID — which is what
  makes per-app hostnames survivable at all: those hostnames are not the RP
  ID, and are only usable for passkeys where `available_for_host?/1` below
  says so.

  Widening the RP ID to cover more hosts is deliberately not something this
  module offers: an RP ID that spans a zone also lets any other host in that
  zone request assertions for You's credentials, so the fix for a host that
  does not qualify is a hostname under the pinned RP ID, never a broader ID.
  """

  @doc "The relying-party ID `wax_` was configured with at boot."
  def rp_id, do: Application.fetch_env!(:wax_, :rp_id)

  @doc """
  Whether `host` may offer passkeys under the configured RP ID.

  `demo.you.example.com` qualifies under RP ID `you.example.com` (it is the
  RP ID itself, extended with a subdomain label); `demo.example.com` does
  not (the RP ID is not a suffix of it at all). Comparison downcases both
  sides and tolerates one trailing dot (the DNS root label), matching
  `YouWeb.RequestURL`'s normalization for the same reason: a Host header a
  browser sends verbatim, uppercase or dotted, must not silently read as a
  non-match.

  This is a plain suffix check, not the WebAuthn spec's full "registrable
  domain suffix" rule — it does not consult a public-suffix list, so nothing
  here stops `WEBAUTHN_RP_ID=co.uk` from being configured. Browsers enforce
  the real rule client-side and `origin_matches?/2` below is what actually
  gates a ceremony, so a bad RP ID fails closed rather than opening
  anything; this function only decides whether to render the option.
  """
  def available_for_host?(host) when is_binary(host) do
    rp = normalize(rp_id())
    host = normalize(host)
    host == rp or String.ends_with?(host, "." <> rp)
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
  condition. Scheme and port must match the canonical origin exactly — only
  the host is allowed to vary, and only within the RP ID's zone.
  """
  def origin_matches?(client_data_origin, challenge_origin) when is_binary(challenge_origin) do
    with %URI{host: host, scheme: scheme, port: port} when is_binary(host) <-
           URI.parse(client_data_origin),
         %URI{scheme: ^scheme, port: ^port} <- URI.parse(challenge_origin) do
      available_for_host?(host)
    else
      _ -> false
    end
  end

  def origin_matches?(client_data_origin, challenge_origin),
    do: Wax.origins_match?(client_data_origin, challenge_origin)

  defp normalize(host) do
    host = String.downcase(host)
    if String.ends_with?(host, "."), do: binary_part(host, 0, byte_size(host) - 1), else: host
  end
end
