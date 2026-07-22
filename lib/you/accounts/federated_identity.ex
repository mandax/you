defmodule You.Accounts.FederatedIdentity do
  use Ecto.Schema
  import Ecto.Changeset

  schema "federated_identities" do
    field :provider, :string
    field :subject, :string
    field :email, :string
    belongs_to :user, You.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset for creating a federated identity.
  """
  def changeset(federated_identity, attrs) do
    federated_identity
    |> cast(attrs, [:user_id, :provider, :subject, :email])
    |> validate_required([:user_id, :provider, :subject, :email])
    |> unique_constraint([:provider, :subject])
    |> foreign_key_constraint(:user_id)
  end
end
