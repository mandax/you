defmodule You.WebAuthnTest do
  use ExUnit.Case, async: false

  alias You.WebAuthn

  # config/test.exs pins `rp_id: "example.com"` so this exercises the same
  # suffix check a real deployment relies on, rather than `:auto`.
  describe "rp_id/0" do
    test "reads the value wax_ was configured with at boot" do
      assert WebAuthn.rp_id() == "example.com"
    end
  end

  describe "available_for_host?/1" do
    test "the RP ID itself qualifies" do
      assert WebAuthn.available_for_host?("example.com")
    end

    test "a subdomain of the RP ID qualifies" do
      assert WebAuthn.available_for_host?("demo.example.com")
      assert WebAuthn.available_for_host?("www.example.com")
    end

    test "a host outside the RP ID's zone does not qualify" do
      refute WebAuthn.available_for_host?("demo-example.com")
      refute WebAuthn.available_for_host?("example.org")
      refute WebAuthn.available_for_host?("notexample.com")
    end

    test "case and a trailing dot are normalized, matching YouWeb.RequestURL" do
      assert WebAuthn.available_for_host?("WWW.EXAMPLE.COM")
      assert WebAuthn.available_for_host?("example.com.")
      assert WebAuthn.available_for_host?("DEMO.Example.COM.")
    end

    test "nil refuses rather than raising" do
      refute WebAuthn.available_for_host?(nil)
    end

    test "changing the configured RP ID changes which hosts qualify" do
      original = Application.fetch_env!(:wax_, :rp_id)
      Application.put_env(:wax_, :rp_id, "you.example.com")

      try do
        assert WebAuthn.available_for_host?("demo.you.example.com")
        refute WebAuthn.available_for_host?("demo.example.com")
      after
        Application.put_env(:wax_, :rp_id, original)
      end
    end

    test "a malformed host that would satisfy a naive suffix check does not qualify" do
      refute WebAuthn.available_for_host?(".example.com")
      refute WebAuthn.available_for_host?("a..example.com")
      refute WebAuthn.available_for_host?("evil.com\\.example.com")
      refute WebAuthn.available_for_host?("evil.com%2e.example.com")
      refute WebAuthn.available_for_host?("")
    end
  end

  # config/test.exs pins origin: "https://example.com", rp_id: "example.com".
  describe "origin_matches?/2" do
    test "the canonical origin matches" do
      assert WebAuthn.origin_matches?("https://example.com", "https://example.com")
    end

    test "a subdomain of the RP ID matches" do
      assert WebAuthn.origin_matches?("https://demo.example.com", "https://example.com")
    end

    test "a host outside the RP ID's zone does not match" do
      refute WebAuthn.origin_matches?("https://example.org", "https://example.com")
    end

    test "a scheme mismatch does not match" do
      refute WebAuthn.origin_matches?("http://demo.example.com", "https://example.com")
    end

    test "a port mismatch does not match" do
      refute WebAuthn.origin_matches?("https://demo.example.com:8443", "https://example.com")
    end

    test "userinfo, path, query or fragment on the client origin refuses it outright" do
      refute WebAuthn.origin_matches?(
               "https://evil.com@demo.example.com",
               "https://example.com"
             )

      refute WebAuthn.origin_matches?("https://demo.example.com/path", "https://example.com")
      refute WebAuthn.origin_matches?("https://demo.example.com?q=1", "https://example.com")
      refute WebAuthn.origin_matches?("https://demo.example.com#frag", "https://example.com")
    end

    test "an empty string or a string with no host does not match" do
      refute WebAuthn.origin_matches?("", "https://example.com")
      refute WebAuthn.origin_matches?("null", "https://example.com")
      refute WebAuthn.origin_matches?("not a url", "https://example.com")
    end

    # Wax.ClientData.parse_raw_json/1 assigns `origin` straight from a JSON
    # field with no type check, so a hostile client_data_origin reaches here
    # as whatever JSON produced: nil for a JSON null, a number, a list, a
    # map. Every shape must resolve to `false`, never raise — a crash here
    # is a 500 on a pre-auth endpoint (finish_authentication/2).
    test "a non-binary client origin refuses without raising" do
      refute WebAuthn.origin_matches?(nil, "https://example.com")
      refute WebAuthn.origin_matches?(42, "https://example.com")
      refute WebAuthn.origin_matches?([], "https://example.com")
      refute WebAuthn.origin_matches?(%{}, "https://example.com")
    end
  end
end
