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
    field :brand_color_dark, :string
    field :accent_color_dark, :string
    field :theme_mode, :string, default: "system"
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
  @theme_modes ~w(system light dark)

  @doc "How an app's login page picks a theme. `system` follows the visitor."
  def theme_modes, do: @theme_modes

  @doc """
  The sign-in methods this app offers, given what the instance supports.

  A `nil` column means the app follows the instance rather than pinning a list,
  so a method added to You later reaches it. This is the one place that
  convention is interpreted — callers ask, they do not match on nil.
  """
  def resolved_methods(%__MODULE__{enabled_methods: nil}, available), do: available

  def resolved_methods(%__MODULE__{enabled_methods: methods}, available),
    do: Enum.filter(available, &(&1 in methods))

  def resolved_methods(nil, available), do: available

  @doc """
  The identity providers this app offers, given what the instance has enabled.

  Same convention as `resolved_methods/2`: `nil` follows the instance.
  """
  def resolved_providers(%__MODULE__{enabled_providers: nil}, available), do: available

  def resolved_providers(%__MODULE__{enabled_providers: slugs}, available),
    do: Enum.filter(available, &(&1 in slugs))

  def resolved_providers(nil, available), do: available

  @doc "Whether the app pins its own list rather than following the instance."
  def restricts_methods?(%__MODULE__{enabled_methods: nil}), do: false
  def restricts_methods?(_), do: true

  @doc "Whether the app pins its own provider list rather than following the instance."
  def restricts_providers?(%__MODULE__{enabled_providers: nil}), do: false
  def restricts_providers?(_), do: true

  @doc """
  Black or white, whichever stays legible on `hex`.

  An admin picking a brand colour is choosing a background; the text on top
  of it has to be readable either way, so it is derived rather than configured.
  Uses WCAG relative luminance with the standard 0.179 crossover.
  """
  def contrast_on("#" <> <<r::binary-2, g::binary-2, b::binary-2>>) do
    if luminance(r) * 0.2126 + luminance(g) * 0.7152 + luminance(b) * 0.0722 > 0.179 do
      "#000000"
    else
      "#ffffff"
    end
  end

  def contrast_on(_), do: "#ffffff"

  defp luminance(component) do
    channel = String.to_integer(component, 16) / 255

    if channel <= 0.03928,
      do: channel / 12.92,
      else: :math.pow((channel + 0.055) / 1.055, 2.4)
  end

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
      :brand_color_dark,
      :accent_color_dark,
      :theme_mode,
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
    |> validate_format(:brand_color_dark, ~r/^#[0-9a-fA-F]{6}$/)
    |> validate_format(:accent_color_dark, ~r/^#[0-9a-fA-F]{6}$/)
    |> validate_inclusion(:theme_mode, @theme_modes)
    |> validate_length(:headline, max: 200)
    |> validate_length(:subtitle, max: 200)
    |> validate_change(:logo_url, &validate_http_url/2)
    |> validate_change(:tos_url, &validate_http_url/2)
    |> validate_change(:privacy_url, &validate_http_url/2)
    |> validate_change(:background_image_url, &validate_http_url/2)
    |> validate_length(:email_from_name, max: 100)
    # An empty list would lock every user out of the app with no way back in
    # through the login page. `nil` is the way to say "follow the instance".
    |> validate_length(:enabled_methods,
      min: 1,
      message: "must offer at least one sign-in method"
    )
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
