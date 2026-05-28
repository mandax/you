defmodule You.Accounts.RecoveryCode do
  use Ecto.Schema
  import Ecto.Changeset

  schema "recovery_codes" do
    field :code_hash, :string
    field :used, :boolean, default: false
    belongs_to :user, You.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(recovery_code, attrs) do
    recovery_code
    |> cast(attrs, [:code_hash, :used, :user_id])
    |> validate_required([:code_hash, :user_id])
  end
end
