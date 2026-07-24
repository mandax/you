defmodule You.IAM.Claims do
  @moduledoc """
  Builds JWT claims for the scopes granted to a user.

  Shared by `You.IAM.Server` (Erlang distribution) and `YouWeb.OIDCController`
  (HTTP token endpoint).
  """

  @doc """
  Builds the JWT claims map for the granted scopes.
  """
  def build_scoped_claims(user, scopes) do
    base = %{sub: user.id, app: "you"}

    scopes
    |> Enum.reduce(base, fn
      "email", acc -> Map.put(acc, :email, user.email)
      "profile", acc -> acc |> Map.put(:email, user.email) |> Map.put(:name, user.email)
      "roles", acc -> acc |> Map.put(:email, user.email) |> Map.put(:role, user_role(user))
      _, acc -> acc
    end)
  end

  @doc """
  Returns the user's role ("admin" or "user") from the account's admin flag,
  so consumer apps can gate on it.
  """
  def user_role(%{is_admin: true}), do: "admin"
  def user_role(_), do: "user"
end
