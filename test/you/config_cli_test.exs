defmodule You.Config.CLITest do
  @moduledoc """
  Bundles have to be scriptable: CI promoting a configuration, backup
  automation, and disaster recovery — which is exactly when the console may be
  the thing that is unavailable.
  """
  use You.DataCase, async: false

  alias You.Config.CLI
  alias You.Settings

  @password "a-long-enough-password"

  setup do
    dir = Path.join(System.tmp_dir!(), "you_bundle_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    System.put_env("YOU_BUNDLE_PASSWORD", @password)
    on_exit(fn -> System.delete_env("YOU_BUNDLE_PASSWORD") end)

    %{path: Path.join(dir, "config.you-bundle"), dir: dir}
  end

  describe "export" do
    test "writes a sealed bundle that import can read back", %{path: path} do
      Settings.set(:jwt_expiry_hours, 6)

      assert {:ok, ^path} = CLI.export(path)
      assert File.exists?(path)

      Settings.set(:jwt_expiry_hours, 1)

      assert {:ok, summary} = CLI.import(path)
      assert summary.settings > 0
      assert Settings.get(:jwt_expiry_hours) == 6
    end

    test "what it writes is not readable without the password", %{path: path} do
      Settings.set(:smtp_username, "postmaster@example.com")

      assert {:ok, ^path} = CLI.export(path)

      refute File.read!(path) =~ "postmaster@example.com"
    end

    test "refuses to overwrite an existing bundle unless forced", %{path: path} do
      assert {:ok, ^path} = CLI.export(path)

      assert {:error, {:already_exists, ^path}} = CLI.export(path)
      assert {:ok, ^path} = CLI.export(path, force: true)
    end

    test "refuses a password shorter than the vault's minimum", %{path: path} do
      System.put_env("YOU_BUNDLE_PASSWORD", "short")

      assert {:error, {:password_too_short, _min}} = CLI.export(path)
      refute File.exists?(path)
    end
  end

  describe "the password never comes from argv" do
    test "a password file wins over the environment", %{path: path, dir: dir} do
      file = Path.join(dir, "password")
      File.write!(file, "from-the-password-file\n")
      System.put_env("YOU_BUNDLE_PASSWORD", "from-the-environment")

      assert {:ok, ^path} = CLI.export(path, password_file: file)

      assert {:error, :wrong_password} = CLI.import(path)
      assert {:ok, _summary} = CLI.import(path, password_file: file)
    end

    test "a missing password file is an error, not a silent prompt", %{path: path, dir: dir} do
      missing = Path.join(dir, "no-such-file")

      assert {:error, {:read_failed, ^missing, _reason}} =
               CLI.export(path, password_file: missing)
    end
  end

  describe "preview" do
    test "reports what an import would change without writing", %{path: path} do
      Settings.set(:jwt_expiry_hours, 9)
      assert {:ok, ^path} = CLI.export(path)
      Settings.set(:jwt_expiry_hours, 1)

      assert {:ok, preview} = CLI.preview(path)
      assert Enum.any?(preview.settings, &(&1.key == "jwt_expiry_hours"))

      assert Settings.get(:jwt_expiry_hours) == 1
    end
  end

  describe "errors" do
    test "a wrong password is refused", %{path: path} do
      assert {:ok, ^path} = CLI.export(path)
      System.put_env("YOU_BUNDLE_PASSWORD", "a-different-password")

      assert {:error, :wrong_password} = CLI.import(path)
    end

    test "a file that is not a bundle is refused", %{dir: dir} do
      path = Path.join(dir, "not-a-bundle")
      File.write!(path, "hello")

      assert {:error, :malformed} = CLI.import(path)
    end

    test "a missing file is reported by name", %{dir: dir} do
      path = Path.join(dir, "absent.you-bundle")

      assert {:error, {:read_failed, ^path, :enoent}} = CLI.import(path)
      assert CLI.describe_error({:read_failed, path, :enoent}) =~ "absent.you-bundle"
    end

    test "every error renders as one human-readable line" do
      for reason <- [
            {:already_exists, "/tmp/x"},
            {:read_failed, "/tmp/x", :enoent},
            {:write_failed, "/tmp/x", :eacces},
            {:password_too_short, 12},
            :password_mismatch,
            :wrong_password,
            :malformed,
            :unsupported_version
          ] do
        message = CLI.describe_error(reason)
        assert is_binary(message)
        refute message =~ "\n"
      end
    end
  end

  describe "instance identity" do
    test "an exported bundle carries none of it, so a CLI restore cannot clone it", %{path: path} do
      Settings.set(:api_token, "source-api-token")
      Settings.set(:erlang_cookie, "source-cookie")
      Settings.set(:scim_bearer_token, "source-scim-token")

      assert {:ok, ^path} = CLI.export(path)

      Settings.set(:api_token, "destination-api-token")
      Settings.set(:erlang_cookie, "destination-cookie")
      Settings.set(:scim_bearer_token, "destination-scim-token")

      assert {:ok, _summary} = CLI.import(path)

      assert Settings.get(:api_token) == "destination-api-token"
      assert Settings.get(:erlang_cookie) == "destination-cookie"
      assert Settings.get(:scim_bearer_token) == "destination-scim-token"
    end
  end
end
