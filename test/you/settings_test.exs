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
end
