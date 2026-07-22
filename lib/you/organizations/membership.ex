defmodule You.Organizations.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_roles ~w[owner admin member]

  schema "memberships" do
    field :role, :string, default: "member"

    belongs_to :organization, You.Organizations.Organization
    belongs_to :user, You.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :organization_id, :user_id])
    |> validate_required([:role, :organization_id, :user_id])
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint([:organization_id, :user_id])
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:user_id)
  end

  def valid_roles, do: @valid_roles
end
