defmodule You.IAM.Claims do
  @moduledoc """
  Builds JWT claims for the scopes granted to a user.

  Shared by `You.IAM.Server` (Erlang distribution) and `YouWeb.OIDCController`
  (HTTP token endpoint).
  """

  alias You.Roles

  @doc """
  Builds the JWT claims map for the granted scopes. When the token is issued
  for a known app, the `roles` scope carries the user's per-app role
  (`You.Roles`); otherwise it falls back to the global admin flag.
  """
  def build_scoped_claims(user, scopes, app_slug \\ nil) do
    base = %{sub: user.id, app: "you"}

    scopes
    |> Enum.reduce(base, fn
      "email", acc -> Map.put(acc, :email, user.email)
      "profile", acc -> acc |> Map.put(:email, user.email) |> Map.put(:name, user.email)
      "roles", acc -> acc |> Map.put(:email, user.email) |> Map.put(:role, role(user, app_slug))
      _, acc -> acc
    end)
  end

  @doc """
  Returns the user's role ("admin" or "user") from the account's admin flag,
  so consumer apps can gate on it.
  """
  def user_role(%{is_admin: true}), do: "admin"
  def user_role(_), do: "user"

  defp role(user, nil), do: user_role(user)

  defp role(user, app_slug) when is_binary(app_slug),
    do: Roles.role_for(app_slug, user.id)
end
