defmodule You.Settings.EnvSeed do
  @moduledoc """
  Seeds console-editable settings from the environment on first boot.

  Mirrors `You.Mode.Provisioner`: the environment seeds a setting's row only
  when that row does not exist yet, and never again. Once a row exists — set
  by this task or by an admin in the console — the console owns it, and a
  redeploy with the same (or a changed) environment variable does not clobber
  it. Runs before `You.Mode.Provisioner`, so `You.Mode.single?/0` already
  reflects `YOU_MODE` by the time provisioning decides whether to run.
  """

  use Task, restart: :transient

  alias You.Settings
  alias You.Settings.Setting
  alias You.Repo

  @env_keys [
    {"YOU_MODE", :you_mode, :string},
    {"SMTP_HOST", :smtp_host, :string},
    {"SMTP_PORT", :smtp_port, :integer},
    {"SMTP_USERNAME", :smtp_username, :string},
    {"SMTP_PASSWORD", :smtp_password, :string},
    {"MAIL_FROM", :mail_from, :string},
    {"API_TOKEN", :api_token, :string},
    {"ANALYTICS_SRC", :analytics_src, :string},
    {"ANALYTICS_DOMAIN", :analytics_domain, :string}
  ]

  def start_link(_arg), do: Task.start_link(__MODULE__, :run, [])

  @doc "Seeds every env-backed setting that has no row yet. Never raises."
  def run do
    Enum.each(@env_keys, &seed/1)
    :ok
  rescue
    _error -> :ok
  end

  defp seed({env_name, key, type}) do
    with value when is_binary(value) <- present(System.get_env(env_name)),
         nil <- Repo.get_by(Setting, key: Atom.to_string(key)) do
      Settings.set(key, cast(value, type))
    else
      _ -> :ok
    end
  end

  defp cast(value, :integer), do: String.to_integer(value)
  defp cast(value, :string), do: value

  defp present(nil), do: nil

  defp present(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
