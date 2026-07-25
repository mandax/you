defmodule You.Roles do
  @moduledoc """
  Per-app role assignments: `(app, user) -> role`, where role is one of the
  app's `allowed_roles`. Unassigned users implicitly have `"user"` in every
  app. JWTs issued for an app carry this role in their claims.
  """

  import Ecto.Query, warn: false
  alias You.Repo
  alias You.Admin.App
  alias You.Accounts.User
  alias You.Roles.Assignment

  @doc """
  Returns the user's role in the app identified by slug, or `"user"` when
  the app doesn't exist or no role is assigned.
  """
  def role_for(app_slug, user_id) when is_binary(app_slug) do
    Repo.one(
      from a in Assignment,
        join: app in App,
        on: app.id == a.app_id and app.slug == ^app_slug,
        where: a.user_id == ^user_id,
        select: a.role
    ) || "user"
  end

  def role_for(_app_slug, _user_id), do: "user"

  @doc """
  Assigns (or changes) the user's role in the app. The role must be one of
  the app's `allowed_roles`. Returns `{:ok, assignment}`,
  `{:error, :invalid_role}`, or `{:error, changeset}`.
  """
  def set_role(%App{} = app, %User{} = user, role) when is_binary(role) do
    if role in (app.allowed_roles || ["user", "admin"]) do
      result =
        %Assignment{}
        |> Assignment.changeset(%{app_id: app.id, user_id: user.id, role: role})
        |> Repo.insert(
          on_conflict: [set: [role: role]],
          conflict_target: [:app_id, :user_id]
        )

      with {:ok, _} <- result do
        :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
          action: "set_role",
          target: "#{app.slug}:#{user.email}",
          role: role
        })
      end

      result
    else
      {:error, :invalid_role}
    end
  end

  @doc """
  Removes the user's role assignment in the app (back to implicit `"user"`).
  Returns the number deleted (0 or 1).
  """
  def remove_role(%App{} = app, %User{} = user) do
    {count, _} =
      Repo.delete_all(from a in Assignment, where: a.app_id == ^app.id and a.user_id == ^user.id)

    count
  end

  @doc """
  Lists all users with their role in the app, sorted by email. Every user
  appears exactly once, unassigned users with role `"user"`.
  """
  def list_for_app(%App{} = app) do
    assigned =
      Repo.all(
        from a in Assignment,
          join: u in User,
          on: u.id == a.user_id,
          where: a.app_id == ^app.id,
          select: {u, a.role}
      )

    assigned_ids = Enum.map(assigned, fn {u, _} -> u.id end)

    unassigned =
      Repo.all(
        from u in User,
          where: u.id not in ^assigned_ids,
          order_by: u.email
      )

    (Enum.map(assigned, fn {u, role} -> {u, role} end) ++
       Enum.map(unassigned, &{&1, "user"}))
    |> Enum.sort_by(fn {u, _} -> u.email end)
  end
end
