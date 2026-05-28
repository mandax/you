defmodule You.Settings do
  @moduledoc """
  Reads and caches instance configuration from the `settings` table.

  Defaults:
  - `session_expiry_hours` — 24
  - `jwt_expiry_hours` — 1
  - `code_expiry_minutes` — 5
  - `magic_link_expiry_minutes` — 15
  """

  alias You.Settings.Setting
  alias You.Repo

  @defaults %{
    session_expiry_hours: 24,
    jwt_expiry_hours: 1,
    code_expiry_minutes: 5,
    magic_link_expiry_minutes: 15
  }

  @doc """
  Returns the value for a setting key, falling back to the default if not configured.
  """
  def get(key) when is_atom(key) do
    key_str = Atom.to_string(key)

    case Repo.get_by(Setting, key: key_str) do
      %{value: value} -> String.to_integer(value)
      nil -> @defaults[key]
    end
  end

  @doc """
  Sets a setting value. Upserts — creates if missing, updates if exists.
  """
  def set(key, value) when is_atom(key) and is_integer(value) do
    key_str = Atom.to_string(key)
    value_str = Integer.to_string(value)

    case Repo.get_by(Setting, key: key_str) do
      nil ->
        Repo.insert!(%Setting{key: key_str, value: value_str})

      existing ->
        existing |> Ecto.Changeset.change(value: value_str) |> Repo.update!()
    end

    :ok
  end
end
