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
  Returns the user's role in the app identified by slug.

  Falls back to the app's `default_role` when there is no explicit assignment,
  and to `"user"` when the app doesn't exist. One left join rather than two
  queries: this sits on the token-issuing path.
  """
  def role_for(app_slug, user_id) when is_binary(app_slug) do
    query =
      from app in App,
        left_join: a in Assignment,
        on: a.app_id == app.id and a.user_id == ^user_id,
        where: app.slug == ^app_slug,
        select: coalesce(a.role, app.default_role)

    Repo.one(query) || "user"
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
  Returns all role assignments as `%{user_id => %{app_id => role}}` for
  rendering per-user role matrices.
  """
  def all_assignments do
    query = from a in Assignment, select: {a.user_id, a.app_id, a.role}

    Enum.reduce(Repo.all(query), %{}, fn {user_id, app_id, role}, acc ->
      Map.update(acc, user_id, %{app_id => role}, &Map.put(&1, app_id, role))
    end)
  end

  @doc """
  Counts explicit assignments per role in the app, as `%{role => count}`.

  Only assigned roles appear: users on the implicit `"user"` role are not
  counted, since removing that role from `allowed_roles` cannot strand them.
  """
  def count_by_role(%App{} = app) do
    query =
      from a in Assignment,
        where: a.app_id == ^app.id,
        group_by: a.role,
        select: {a.role, count(a.id)}

    Map.new(Repo.all(query))
  end

  @doc """
  Assigns `role` to many users at once in a single statement.

  One `insert_all` rather than a call per user: every write serialises through
  SQLite's single writer, so the round-trip count is the cost that matters.
  Returns `{:ok, count}` or `{:error, :invalid_role}`.
  """
  def set_roles(%App{} = app, user_ids, role) when is_list(user_ids) and is_binary(role) do
    if role in (app.allowed_roles || ["user", "admin"]) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        Enum.map(user_ids, fn user_id ->
          %{
            app_id: app.id,
            user_id: to_integer(user_id),
            role: role,
            inserted_at: now,
            updated_at: now
          }
        end)

      {count, _} =
        Repo.insert_all(Assignment, entries,
          on_conflict: [set: [role: role, updated_at: now]],
          conflict_target: [:app_id, :user_id]
        )

      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "set_roles",
        target: app.slug,
        role: role,
        count: count
      })

      {:ok, count}
    else
      {:error, :invalid_role}
    end
  end

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)

  @doc """
  Lists all users with their role in the app, sorted by email. Every user
  appears exactly once, unassigned users carrying the app's `default_role`.
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

    default = app.default_role || "user"

    Enum.sort_by(assigned ++ Enum.map(unassigned, &{&1, default}), fn {u, _} -> u.email end)
  end
end
