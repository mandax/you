defmodule YouWeb.API.V1.JSON do
  @moduledoc """
  Shared serializers and error formatting for the management API.

  These are the only places where structs become wire format: hashes and
  secrets (`hashed_password`, `client_secret_hash`, tokens) never leave the
  app through this module.
  """

  alias You.Accounts.User
  alias You.Admin.App

  def user_json(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      is_admin: user.is_admin,
      confirmed: not is_nil(user.confirmed_at),
      inserted_at: user.inserted_at
    }
  end

  def app_json(%App{} = app) do
    %{
      id: app.id,
      slug: app.slug,
      name: app.name,
      callback_url: app.callback_url,
      launch_url: app.launch_url,
      first_party: app.first_party,
      inserted_at: app.inserted_at,
      updated_at: app.updated_at
    }
  end

  @doc """
  Formats changeset errors as `%{field => [message, ...]}`.
  """
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn
        {key, value}, acc when is_binary(value) or is_atom(value) or is_number(value) ->
          String.replace(acc, "%{#{key}}", to_string(value))

        _opt, acc ->
          acc
      end)
    end)
  end
end
