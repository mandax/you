defmodule You.WebAuthn do
  @moduledoc """
  The instance's WebAuthn relying-party ID and which request hosts may offer
  passkeys under it.

  The RP ID itself is pinned once, at boot, by `WEBAUTHN_RP_ID`
  (`config/runtime.exs`) — environment-only, see `You.Settings.forbidden_keys/0`.
  This module does not change it per request; it only answers whether the
  *current* host is allowed to use it, per the WebAuthn spec's rule that an RP
  ID must be the host itself or a registrable domain suffix of it.

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
  not (the RP ID is not a suffix of it at all).

  `nil` is treated as unrestricted — it comes from call sites that render a
  host-independent preview (the app settings screen's method list) rather
  than gate a live request, so there is no host to check against.
  """
  def available_for_host?(nil), do: true

  def available_for_host?(host) when is_binary(host) do
    rp_id = rp_id()
    host == rp_id or String.ends_with?(host, "." <> rp_id)
  end
end
