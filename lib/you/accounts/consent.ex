defmodule You.Accounts.Consent do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  schema "consents" do
    belongs_to :user, You.Accounts.User
    belongs_to :app, You.Admin.App
    field :scopes, {:array, :string}
    field :granted_at, :utc_datetime
    field :expires_at, :utc_datetime
    timestamps()
  end

  def changeset(consent, attrs) do
    consent
    |> cast(attrs, [:user_id, :app_id, :scopes, :granted_at, :expires_at])
    |> validate_required([:user_id, :app_id, :scopes, :granted_at, :expires_at])
    |> unique_constraint(:user_id, name: :consents_user_id_app_id_index)
  end
end
