defmodule You.Settings.EnvSeedTest do
  @moduledoc """
  The environment seeds a setting's row once; after that, the console owns
  it. A redeploy with the same — or a different — environment variable must
  never overwrite a row that already exists.
  """
  use You.DataCase, async: false

  alias You.Settings
  alias You.Settings.EnvSeed
  alias You.Settings.Setting
  alias You.Repo

  setup do
    on_exit(fn ->
      System.delete_env("API_TOKEN")
      System.delete_env("MAIL_FROM")
      System.delete_env("YOU_MODE")
      Application.put_env(:you, :api_token, "test-api-token")
    end)
  end

  test "seeds a setting from the environment when no row exists" do
    refute Repo.get_by(Setting, key: "api_token")
    System.put_env("API_TOKEN", "from-env")

    assert :ok = EnvSeed.run()

    assert Settings.get(:api_token) == "from-env"
  end

  test "never overwrites a row an admin already created" do
    Settings.set(:api_token, "console-owned")
    System.put_env("API_TOKEN", "from-env")

    assert :ok = EnvSeed.run()

    assert Settings.get(:api_token) == "console-owned"
  end

  test "a redeploy with a changed environment variable does not clobber the console value" do
    System.put_env("MAIL_FROM", "first@example.com")
    assert :ok = EnvSeed.run()
    assert Settings.get(:mail_from) == "first@example.com"

    Settings.set(:mail_from, "admin@example.com")

    System.put_env("MAIL_FROM", "second@example.com")
    assert :ok = EnvSeed.run()

    assert Settings.get(:mail_from) == "admin@example.com"
  end

  test "blank environment variables are treated as unset" do
    System.put_env("YOU_MODE", "")
    assert :ok = EnvSeed.run()

    refute Repo.get_by(Setting, key: "you_mode")
    assert Settings.get(:you_mode) == "multi"
  end
end
