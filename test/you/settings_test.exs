defmodule You.SettingsTest do
  use You.DataCase, async: false

  alias You.Settings

  describe "get/1 and set/2" do
    test "returns default for unset key" do
      assert Settings.get(:jwt_expiry_hours) == 1
      assert Settings.get(:session_expiry_hours) == 24
      assert Settings.get(:code_expiry_minutes) == 5
      assert Settings.get(:magic_link_expiry_minutes) == 15
    end

    test "set updates value that get returns" do
      :ok = Settings.set(:jwt_expiry_hours, 2)
      assert Settings.get(:jwt_expiry_hours) == 2
    end
  end

  describe "forbidden keys" do
    test "set/2 rejects every key that must stay environment-only" do
      for key <- Settings.forbidden_keys() do
        assert_raise ArgumentError, fn -> Settings.set(key, "anything") end
      end
    end
  end

  describe "settings are read where they are used, not mirrored into app env" do
    test "you_mode is what You.Mode reports" do
      Settings.set(:you_mode, "single")
      assert You.Mode.mode() == :single
      assert You.Mode.single?()

      Settings.set(:you_mode, "multi")
      assert You.Mode.mode() == :multi
      refute You.Mode.single?()
    end

    test "api_token is what the management API compares against" do
      Settings.set(:api_token, "new-token")
      assert Settings.api_token() == "new-token"

      Settings.set(:api_token, "")
      assert Settings.api_token() == nil
    end

    test "analytics requires both fields" do
      Settings.set(:analytics_src, "https://a.example.com/script.js")
      assert Settings.analytics() == nil

      Settings.set(:analytics_domain, "example.com")

      assert Settings.analytics() == [
               src: "https://a.example.com/script.js",
               domain: "example.com"
             ]
    end
  end
end
