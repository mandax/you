defmodule You.Invitations.Invitation do
  @moduledoc """
  An admin's invitation for someone to join an app. See `You.Invitations`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  schema "invitations" do
    field :email, :string
    field :token, :binary
    field :role, :string
    field :accepted_at, :utc_datetime

    belongs_to :app, You.Admin.App
    belongs_to :invited_by, You.Accounts.User
    belongs_to :accepted_by, You.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :token, :role, :app_id, :invited_by_id])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:email, :token])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> foreign_key_constraint(:app_id)
    |> unique_constraint(:token)
  end
end
