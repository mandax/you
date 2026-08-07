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
  end
end
