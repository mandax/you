defmodule You.Organizations do
  @moduledoc """
  The Organizations context: multi-tenancy primitives.

  Users can belong to organizations with a role (owner / admin / member).
  """

  import Ecto.Query, warn: false
  alias You.Repo

  alias You.Organizations.{Organization, Membership}
  alias You.Accounts.User

  @doc """
  Creates a new organization.

  ## Examples

      iex> create_organization(%{name: "Acme Corp", slug: "acme-corp"})
      {:ok, %Organization{}}

      iex> create_organization(%{name: "", slug: ""})
      {:error, %Ecto.Changeset{}}

  """
  def create_organization(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets an organization by id.

  Returns `%Organization{}` or `nil`.
  """
  def get_organization(id) do
    Repo.get(Organization, id)
  end

  @doc """
  Lists all organizations.
  """
  def list_organizations do
    Repo.all(from o in Organization, order_by: [asc: o.name])
  end

  @doc """
  Lists all organizations with their member count, newest first.

  Returns a list of `{organization, member_count}` tuples.
  """
  def list_organizations_with_counts do
    from(o in Organization,
      left_join: m in assoc(o, :memberships),
      group_by: o.id,
      order_by: [asc: o.name],
      select: {o, count(m.id)}
    )
    |> Repo.all()
  end

  @doc """
  Adds a user to an organization with the given role.

  Defaults role to "member". Returns `{:ok, %Membership{}}` or `{:error, %Ecto.Changeset{}}`.

  ## Examples

      iex> add_member(organization, user, "admin")
      {:ok, %Membership{role: "admin"}}

  """
  def add_member(%Organization{} = org, %User{} = user, role \\ "member") do
    %Membership{}
    |> Membership.changeset(%{
      organization_id: org.id,
      user_id: user.id,
      role: role
    })
    |> Repo.insert()
  end

  @doc """
  Removes a user from an organization.

  Returns `{:ok, membership}` or `{:error, :not_found}`.
  """
  def remove_member(%Organization{} = org, %User{} = user) do
    case Repo.get_by(Membership, organization_id: org.id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      membership ->
        Repo.delete(membership)
    end
  end

  @doc """
  Lists all members (users + their roles) for an organization.

  Returns a list of `{user, membership}` tuples.
  """
  def list_members(%Organization{} = org) do
    from(m in Membership,
      where: m.organization_id == ^org.id,
      join: u in assoc(m, :user),
      preload: [user: u]
    )
    |> Repo.all()
    |> Enum.map(fn m -> {m.user, m.role} end)
  end

  @doc """
  Updates a member's role in an organization.

  Returns `{:ok, membership}` or `{:error, :not_found}` or `{:error, changeset}`.
  """
  def update_member_role(%Organization{} = org, %User{} = user, role) do
    case Repo.get_by(Membership, organization_id: org.id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      membership ->
        membership
        |> Membership.changeset(%{role: role})
        |> Repo.update()
    end
  end
end
