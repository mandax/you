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

  An app's declared static claims (`custom_claims` on the app row) are merged
  underneath, so its tenant id, plan or feature flags arrive in the token
  instead of costing the app a second round-trip. They can only add: the
  claims You issues are applied on top, and the reserved names are refused at
  write time and filtered again here.
  """
  def build_scoped_claims(user, scopes, app_slug \\ nil) do
    base = %{sub: user.id, app: "you"}

    # Only on guests: an absent `guest` claim means a real account, so a
    # consumer reading `payload["guest"]` gets nil rather than a claim it has
    # to remember to check for false.
    base = if You.Guests.guest?(user), do: Map.put(base, :guest, true), else: base

    issued =
      Enum.reduce(scopes, base, fn
        "email", acc -> Map.put(acc, :email, user.email)
        "profile", acc -> acc |> Map.put(:email, user.email) |> Map.put(:name, user.email)
        "roles", acc -> acc |> Map.put(:email, user.email) |> Map.put(:role, role(user, app_slug))
        _, acc -> acc
      end)

    Map.merge(custom_claims(app_slug), issued)
  end

  @doc """
  The static claims declared by the app with this slug, or `%{}`.

  Nil and unknown slugs are ordinary: a first-party login carries no app.
  """
  def custom_claims(app_slug) when is_binary(app_slug) do
    app_slug |> You.Admin.get_app_by_slug() |> You.Admin.App.custom_claims()
  end

  def custom_claims(_app_slug), do: %{}

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
