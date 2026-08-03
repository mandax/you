defmodule You.MailerTest do
  @moduledoc """
  SMTP relay, credentials and the from-address are read from `You.Settings`
  at send time, so a console edit is live. `transport/0` and
  `production_ready?/0` report that runtime state, not whatever was compiled
  in at boot.
  """
  use You.DataCase, async: false

  alias You.Mailer
  alias You.Settings

  setup do
    on_exit(fn -> Application.delete_env(:you, :mail_transport) end)
  end

  describe "transport/0" do
    test "reports what runtime.exs configured when Settings has no SMTP host" do
      Application.put_env(:you, :mail_transport, :smtp)
      on_exit(fn -> Application.delete_env(:you, :mail_transport) end)

      assert Mailer.transport() == :smtp
    end

    test "falls back to the configured adapter when nothing declared one" do
      Application.delete_env(:you, :mail_transport)

      # The test environment uses the Test adapter, which is neither delivery
      # nor the in-memory fallback.
      assert Mailer.transport() == :test
    end

    test "an SMTP host configured in Settings wins over the boot-time transport" do
      Application.put_env(:you, :mail_transport, :local)
      Settings.set(:smtp_host, "smtp.example.com")

      assert Mailer.transport() == :smtp
    end

    test "clearing the SMTP host in Settings falls back to the compiled config" do
      Settings.set(:smtp_host, "smtp.example.com")
      assert Mailer.transport() == :smtp

      Settings.set(:smtp_host, "")
      assert Mailer.transport() == :test
    end
  end

  describe "production_ready?/0" do
    test "only SMTP counts as delivering mail" do
      on_exit(fn -> Application.delete_env(:you, :mail_transport) end)

      Application.put_env(:you, :mail_transport, :smtp)
      assert Mailer.production_ready?()

      Application.put_env(:you, :mail_transport, :local)
      refute Mailer.production_ready?()
    end

    test "an instance with no SMTP at boot becomes ready once Settings has one" do
      refute Mailer.production_ready?()

      Settings.set(:smtp_host, "smtp.example.com")

      assert Mailer.production_ready?()
    end
  end

  describe "from_address/0" do
    test "falls back to the compiled default when Settings has none" do
      assert Mailer.from_address() == Application.get_env(:you, :mail_from, "contact@example.com")
    end

    test "the console's mail_from wins when set" do
      Settings.set(:mail_from, "console@example.com")
      assert Mailer.from_address() == "console@example.com"
    end
  end
end
