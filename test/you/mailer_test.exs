defmodule You.MailerTest do
  use ExUnit.Case, async: false

  alias You.Mailer

  describe "transport/0" do
    test "reports what runtime.exs configured" do
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
  end

  describe "production_ready?/0" do
    test "only SMTP counts as delivering mail" do
      on_exit(fn -> Application.delete_env(:you, :mail_transport) end)

      Application.put_env(:you, :mail_transport, :smtp)
      assert Mailer.production_ready?()

      Application.put_env(:you, :mail_transport, :local)
      refute Mailer.production_ready?()
    end
  end
end
