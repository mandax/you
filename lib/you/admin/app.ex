defmodule You.Admin.App do
  use Ecto.Schema
  import Ecto.Changeset

  schema "apps" do
    field :slug, :string
    field :name, :string
    field :callback_url, :string
    field :launch_url, :string
    field :client_secret_hash, :binary
    timestamps()
  end

  def changeset(app, attrs) do
    app
    |> cast(attrs, [:slug, :name, :callback_url, :launch_url])
    |> validate_required([:slug, :name, :callback_url])
    |> unique_constraint(:slug)
  end
end
