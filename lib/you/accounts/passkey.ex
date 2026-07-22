defmodule You.Accounts.Passkey do
  @moduledoc """
  A WebAuthn credential (passkey) registered to a user.

  Stores the credential ID, the COSE public key (term_to_binary encoded for
  storage in SQLite), and the current sign count used for clone detection.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "user_passkeys" do
    belongs_to :user, You.Accounts.User
    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :label, :string
    field :aaguid, :binary

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(passkey, attrs) do
    passkey
    |> cast(attrs, [:user_id, :credential_id, :public_key, :sign_count, :label, :aaguid])
    |> validate_required([:user_id, :credential_id, :public_key])
    |> unique_constraint(:credential_id)
    |> validate_number(:sign_count, greater_than_or_equal_to: 0)
  end

  @doc """
  Encodes a COSE public-key map for persistent storage.

  Uses `:erlang.term_to_binary/1` so that the map with integer keys round-trips
  losslessly, even through a binary-only column like SQLite's `:binary`.
  """
  def encode_cose_key(cose_key) when is_map(cose_key) do
    :erlang.term_to_binary(cose_key)
  end

  @doc """
  Decodes a COSE public key that was stored with `encode_cose_key/1`.
  """
  def decode_cose_key(binary) when is_binary(binary) do
    :erlang.binary_to_term(binary)
  end
end
