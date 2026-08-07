defmodule You.WebAuthnOriginTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Drives a real `Wax.register/3` ceremony end to end, rather than stopping at
  `You.WebAuthn.available_for_host?/1` or the controller's `/start` endpoint.

  `Wax.valid_origin?/2` (`deps/wax_/lib/wax.ex`) calls the challenge's
  `origin_verify_fun` MFA directly — the default, `Wax.origins_match?/2`, is
  an exact string match against the single configured `origin`, so a
  subdomain request fails there even when `available_for_host?/1` says the
  host qualifies. `/start` never reaches this check (it only builds and
  returns a challenge), which is why a positive test that stops at `/start`
  cannot catch a broken `origin_verify_fun`. This builds a minimal but real
  "none"-format attestation — no attestation signature to fake, so what's
  under test is exactly `valid_origin?/2` and `valid_rp_id?/2`, both of
  which `Wax.register/3` runs before returning `:ok`.

  config/test.exs pins `origin: "https://example.com"`, `rp_id:
  "example.com"`.
  """

  @rp_id "example.com"
  @canonical_origin "https://example.com"

  defp challenge(origin_verify_fun) do
    Wax.new_registration_challenge(
      rp_id: @rp_id,
      origin: @canonical_origin,
      attestation: "none",
      origin_verify_fun: origin_verify_fun
    )
  end

  # A syntactically valid "none"-format attestation object: no attStmt to
  # verify, so registration succeeds purely on origin/RP ID/flag checks.
  defp attestation_object do
    credential_id = :crypto.strong_rand_bytes(16)

    cose_key = %{
      1 => 2,
      3 => -7,
      -1 => 1,
      -2 => :crypto.strong_rand_bytes(32),
      -3 => :crypto.strong_rand_bytes(32)
    }

    attested_credential_data =
      <<0::128>> <>
        <<byte_size(credential_id)::unsigned-big-integer-size(16)>> <>
        credential_id <> CBOR.encode(cose_key)

    # Flags: bit 0 (user present) and bit 6 (attested credential data
    # included) set; no extension data.
    flags = <<0b01000001>>

    auth_data =
      :crypto.hash(:sha256, @rp_id) <>
        flags <> <<0::unsigned-big-integer-size(32)>> <> attested_credential_data

    CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => auth_data})
  end

  defp client_data_json(challenge, origin) do
    Jason.encode!(%{
      "type" => "webauthn.create",
      "challenge" => Base.url_encode64(challenge.bytes, padding: false),
      "origin" => origin
    })
  end

  describe "Wax's default origin check (the bug this fixes)" do
    test "rejects a subdomain of the RP ID outright" do
      challenge = challenge({Wax, :origins_match?, []})
      client_data = client_data_json(challenge, "https://demo.example.com")

      assert {:error, %Wax.InvalidClientDataError{reason: :origin_mismatch}} =
               Wax.register(attestation_object(), client_data, challenge)
    end
  end

  describe "You.WebAuthn.origin_matches?/2" do
    test "still accepts the canonical origin" do
      challenge = challenge({You.WebAuthn, :origin_matches?, []})
      client_data = client_data_json(challenge, @canonical_origin)

      assert {:ok, {_auth_data, _attestation}} =
               Wax.register(attestation_object(), client_data, challenge)
    end

    test "accepts a subdomain of the configured RP ID" do
      challenge = challenge({You.WebAuthn, :origin_matches?, []})
      client_data = client_data_json(challenge, "https://demo.example.com")

      assert {:ok, {_auth_data, _attestation}} =
               Wax.register(attestation_object(), client_data, challenge)
    end

    test "rejects a host outside the RP ID's zone" do
      challenge = challenge({You.WebAuthn, :origin_matches?, []})
      client_data = client_data_json(challenge, "https://example.org")

      assert {:error, %Wax.InvalidClientDataError{reason: :origin_mismatch}} =
               Wax.register(attestation_object(), client_data, challenge)
    end

    test "rejects a scheme mismatch even on a qualifying host" do
      challenge = challenge({You.WebAuthn, :origin_matches?, []})
      client_data = client_data_json(challenge, "http://demo.example.com")

      assert {:error, %Wax.InvalidClientDataError{reason: :origin_mismatch}} =
               Wax.register(attestation_object(), client_data, challenge)
    end
  end
end
