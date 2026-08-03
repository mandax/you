defmodule You.Mailer do
  @moduledoc """
  Transactional mail: magic links, email 2FA codes, confirmations, resets.

  SMTP relay, port, credentials and the from-address come from `You.Settings`
  at send time, not from a value baked in at boot: a console edit takes effect
  on the very next email, with nothing to restart. A blank `smtp_host` in
  `Settings` falls back to whatever `config/runtime.exs` compiled in — SMTP
  from the environment, or the in-memory Local adapter — so an instance an
  admin has never touched from the console behaves exactly as it did before
  this existed.

  In production an instance with no SMTP configured falls back to an in-memory
  mailbox (`config/runtime.exs`) so those flows can be exercised during an
  evaluation instead of failing silently. That is not a deployment anyone
  should keep — `production_ready?/0` is what the console asks before it calls
  the install complete.
  """

  use Swoosh.Mailer, otp_app: :you

  alias You.Settings

  @doc "How mail leaves this instance right now: `:smtp`, `:local`, or `:test`."
  def transport do
    if smtp_host() do
      :smtp
    else
      Application.get_env(:you, :mail_transport) ||
        case Application.get_env(:you, __MODULE__)[:adapter] do
          Swoosh.Adapters.SMTP -> :smtp
          Swoosh.Adapters.Test -> :test
          _ -> :local
        end
    end
  end

  @doc "Whether mail actually reaches users right now. False on the in-memory fallback."
  def production_ready?, do: transport() == :smtp

  @doc """
  The from-address for transactional mail: the console's `mail_from` setting
  when set, otherwise the address `config/runtime.exs` computed at boot.
  """
  def from_address do
    present(Settings.get(:mail_from)) ||
      Application.get_env(:you, :mail_from, "contact@example.com")
  end

  @doc false
  def deliver(email), do: deliver(email, [])

  @doc false
  def deliver(email, config) do
    super(email, Keyword.merge(dynamic_config(), config))
  end

  defp smtp_host, do: present(Settings.get(:smtp_host))

  defp dynamic_config do
    case smtp_host() do
      nil ->
        []

      host ->
        auth =
          case {present(Settings.get(:smtp_username)), present(Settings.get(:smtp_password))} do
            {username, password} when is_binary(username) and is_binary(password) ->
              [username: username, password: password, auth: :always]

            _ ->
              []
          end

        [adapter: Swoosh.Adapters.SMTP, relay: host, port: Settings.get(:smtp_port), tls: :always] ++
          auth
    end
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
