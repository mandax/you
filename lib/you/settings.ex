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
    magic_link_expiry_minutes: 15,
    erlang_cookie: "",
    erlang_node_name: "you@you.internal",
    epmd_port: 4369,
    scim_bearer_token: "",
    audit_webhook_url: ""
  }

  @doc """
  Returns the value for a setting key, falling back to the default if not configured.
  Returns the value cast to the same type as the default (integer or string).
  """
  def get(key) when is_atom(key) do
    key_str = Atom.to_string(key)
    default = @defaults[key]

    case Repo.get_by(Setting, key: key_str) do
      %{value: value} -> cast_value(value, default)
      nil -> default
    end
  end

  @doc """
  Returns all setting keys with their current values.
  """
  def all do
    @defaults
    |> Enum.map(fn {key, _default} -> {key, get(key)} end)
    |> Map.new()
  end

  @doc """
  Sets a setting value. Upserts — creates if missing, updates if exists.
  Accepts both integers and strings.
  """
  def set(key, value) when is_atom(key) and is_integer(value) do
    do_set(key, Integer.to_string(value))
  end

  def set(key, value) when is_atom(key) and is_binary(value) do
    do_set(key, value)
  end

  defp do_set(key, value_str) do
    key_str = Atom.to_string(key)

    case Repo.get_by(Setting, key: key_str) do
      nil ->
        Repo.insert!(%Setting{key: key_str, value: value_str})

      existing ->
        existing |> Ecto.Changeset.change(value: value_str) |> Repo.update!()
    end

    :ok
  end

  defp cast_value(value, default) when is_integer(default), do: String.to_integer(value)
  defp cast_value(value, _default), do: value
end
