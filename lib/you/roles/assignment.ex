defmodule You.Roles.Assignment do
  @moduledoc """
  A user's role in one app. Roles are always scoped `(app, user) -> role`
  and must be one of the app's `allowed_roles`; there is no global role
  beyond You's own `is_admin` flag.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "app_user_roles" do
    field :role, :string

    belongs_to :app, You.Admin.App
    belongs_to :user, You.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:app_id, :user_id, :role])
    |> validate_required([:app_id, :user_id, :role])
    |> unique_constraint([:app_id, :user_id])
  end
end
