defmodule You.Mailer do
  @moduledoc """
  Transactional mail: magic links, email 2FA codes, confirmations, resets.

  In production an instance with no SMTP configured falls back to an in-memory
  mailbox (`config/runtime.exs`) so those flows can be exercised during an
  evaluation instead of failing silently. That is not a deployment anyone
  should keep — `production_ready?/0` is what the console asks before it calls
  the install complete.
  """

  use Swoosh.Mailer, otp_app: :you

  @doc "How mail leaves this instance: `:smtp`, `:local`, or `:test`."
  def transport do
    Application.get_env(:you, :mail_transport) ||
      case Application.get_env(:you, __MODULE__)[:adapter] do
        Swoosh.Adapters.SMTP -> :smtp
        Swoosh.Adapters.Test -> :test
        _ -> :local
      end
  end

  @doc "Whether mail actually reaches users. False on the in-memory fallback."
  def production_ready?, do: transport() == :smtp
end
