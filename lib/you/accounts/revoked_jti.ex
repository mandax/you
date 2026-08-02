defmodule You.Accounts.RevokedJti do
  @moduledoc """
  A revoked JWT id.

  Kept apart from `users_tokens` because a revocation is not a user's token:
  service tokens minted by the client-credentials grant carry an app slug as
  their subject, which cannot go in an integer foreign key to `users`, and a
  blocklist entry needs no owner to be meaningful. `subject` is recorded for
  the audit trail only, as free text.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, updated_at: false]

  schema "revoked_jtis" do
    field :jti_hash, :binary
    field :subject, :string
    timestamps()
  end

  @doc false
  def changeset(revoked_jti, attrs) do
    revoked_jti
    |> cast(attrs, [:jti_hash, :subject])
    |> validate_required([:jti_hash])
    |> unique_constraint(:jti_hash)
  end
end
