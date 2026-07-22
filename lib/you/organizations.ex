defmodule You.Organizations do
  @moduledoc """
  The Organizations context — multi-tenancy primitives.

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
  Gets an organization by slug.

  Returns `%Organization{}` or `nil`.
  """
  def get_organization_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Organization, slug: slug)
  end

  @doc """
  Lists all organizations.
  """
  def list_organizations do
    Repo.all(Organization)
  end

  @doc """
  Creates an organization and adds the given user as "owner" in one transaction.

  Returns `{:ok, %{organization: org, membership: membership}}` or `{:error, :organization, changeset, _}` or `{:error, :membership, changeset, _}`.

  ## Examples

      iex> create_organization_with_owner(%{name: "Acme Corp", slug: "acme-corp"}, user)
      {:ok, %{organization: %Organization{}, membership: %Membership{role: "owner"}}}

  """
  def create_organization_with_owner(attrs, %User{} = user) do
    Repo.transact(fn ->
      with {:ok, org} <- create_organization(attrs),
           {:ok, membership} <- add_member(org, user, "owner") do
        {:ok, %{organization: org, membership: membership}}
      else
        {:error, changeset} -> Repo.rollback({:error, changeset})
      end
    end)
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
  Lists all organizations a user belongs to, with their role in each.

  Returns a list of `{organization, role}` tuples.
  """
  def list_user_organizations(%User{} = user) do
    from(m in Membership,
      where: m.user_id == ^user.id,
      join: o in assoc(m, :organization),
      preload: [organization: o]
    )
    |> Repo.all()
    |> Enum.map(fn m -> {m.organization, m.role} end)
  end

  @doc """
  Returns the role a user has in an organization, or `nil` if not a member.
  """
  def member_role(%Organization{} = org, %User{} = user) do
    case Repo.get_by(Membership, organization_id: org.id, user_id: user.id) do
      nil -> nil
      %Membership{role: role} -> role
    end
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
