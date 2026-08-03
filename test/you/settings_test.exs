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

  describe "console edits sync into Application env for boot-read config" do
    test "you_mode flips You.Mode's underlying app env" do
      on_exit(fn -> Application.put_env(:you, :mode, :multi) end)

      Settings.set(:you_mode, "single")
      assert Application.get_env(:you, :mode) == :single

      Settings.set(:you_mode, "multi")
      assert Application.get_env(:you, :mode) == :multi
    end

    test "api_token updates the management API's app env" do
      on_exit(fn -> Application.put_env(:you, :api_token, "test-api-token") end)

      Settings.set(:api_token, "new-token")
      assert Application.get_env(:you, :api_token) == "new-token"

      Settings.set(:api_token, "")
      assert Application.get_env(:you, :api_token) == nil
    end

    test "analytics requires both fields" do
      on_exit(fn -> Application.put_env(:you, :analytics, nil) end)

      Settings.set(:analytics_src, "https://a.example.com/script.js")
      assert Application.get_env(:you, :analytics) == nil

      Settings.set(:analytics_domain, "example.com")

      assert Application.get_env(:you, :analytics) == [
               src: "https://a.example.com/script.js",
               domain: "example.com"
             ]
    end
  end
end
