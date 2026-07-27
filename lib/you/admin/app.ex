defmodule You.Admin.App do
  use Ecto.Schema
  import Ecto.Changeset

  schema "apps" do
    field :slug, :string
    field :name, :string
    field :callback_url, :string
    field :launch_url, :string
    field :logo_url, :string
    field :brand_color, :string
    field :allowed_roles, {:array, :string}, default: ["user", "admin"]
    field :first_party, :boolean, default: false
    field :client_secret_hash, :binary
    timestamps()
  end

  def changeset(app, attrs) do
    app
    |> cast(attrs, [
      :slug,
      :name,
      :callback_url,
      :launch_url,
      :logo_url,
      :brand_color,
      :allowed_roles,
      :first_party
    ])
    |> validate_required([:slug, :name, :callback_url])
    # An app with no allowed roles can never have a role assigned, so every
    # assignment attempt would fail. Keep at least one.
    |> validate_length(:allowed_roles, min: 1)
    |> validate_format(:brand_color, ~r/^#[0-9a-fA-F]{6}$/)
    |> validate_change(:logo_url, fn :logo_url, url ->
      case URI.parse(url) do
        %URI{scheme: scheme} when scheme in ["http", "https"] -> []
        _ -> [logo_url: "must be an http(s) URL"]
      end
    end)
    |> unique_constraint(:slug)
  end
end
