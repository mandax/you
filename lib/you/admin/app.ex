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
    field :headline, :string
    field :subtitle, :string
    field :tos_url, :string
    field :privacy_url, :string
    field :background_image_url, :string
    field :accent_color, :string
    field :email_from_name, :string
    # nil means "everything the instance offers", so a provider or method added
    # later reaches existing apps instead of being silently skipped.
    field :enabled_providers, {:array, :string}
    field :enabled_methods, {:array, :string}
    field :allowed_roles, {:array, :string}, default: ["user", "admin"]
    field :default_role, :string, default: "user"
    field :first_party, :boolean, default: false
    field :client_secret_hash, :binary
    timestamps()
  end

  @auth_methods ~w(password magic_link passkey social)

  @doc "The auth methods an app may enable. `nil` on the column means all of them."
  def auth_methods, do: @auth_methods

  def changeset(app, attrs) do
    app
    |> cast(attrs, [
      :slug,
      :name,
      :callback_url,
      :launch_url,
      :logo_url,
      :brand_color,
      :headline,
      :subtitle,
      :tos_url,
      :privacy_url,
      :background_image_url,
      :accent_color,
      :email_from_name,
      :enabled_providers,
      :enabled_methods,
      :allowed_roles,
      :default_role,
      :first_party
    ])
    |> validate_required([:slug, :name, :callback_url])
    # An app with no allowed roles can never have a role assigned, so every
    # assignment attempt would fail. Keep at least one.
    |> validate_length(:allowed_roles, min: 1)
    |> validate_default_role()
    |> validate_format(:brand_color, ~r/^#[0-9a-fA-F]{6}$/)
    |> validate_format(:accent_color, ~r/^#[0-9a-fA-F]{6}$/)
    |> validate_length(:headline, max: 200)
    |> validate_length(:subtitle, max: 200)
    |> validate_change(:logo_url, &validate_http_url/2)
    |> validate_change(:tos_url, &validate_http_url/2)
    |> validate_change(:privacy_url, &validate_http_url/2)
    |> validate_change(:background_image_url, &validate_http_url/2)
    |> validate_length(:email_from_name, max: 100)
    |> validate_subset(:enabled_methods, @auth_methods)
    |> unique_constraint(:slug)
  end

  defp validate_http_url(field, url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> []
      _ -> [{field, "must be an http(s) URL"}]
    end
  end

  # Unassigned users resolve to `default_role`, so a default outside
  # `allowed_roles` would hand out a role the app rejects on assignment.
  #
  # Checked against the resolved fields rather than the changes, so that
  # dropping the default out of `allowed_roles` fails too, not only editing
  # `default_role` itself.
  defp validate_default_role(changeset) do
    allowed = get_field(changeset, :allowed_roles) || []
    default = get_field(changeset, :default_role)

    if is_nil(default) or default in allowed do
      changeset
    else
      add_error(changeset, :default_role, "must be one of the allowed roles")
    end
  end
end
