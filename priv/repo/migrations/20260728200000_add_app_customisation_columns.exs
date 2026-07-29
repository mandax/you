defmodule You.Repo.Migrations.AddAppCustomisationColumns do
  use Ecto.Migration

  # Landed as one migration so the parallel feature work that consumes these
  # columns never has to touch the schema concurrently.
  #
  # `enabled_providers` and `enabled_methods` are null rather than a default
  # list: null means "everything the instance offers", so adding a new provider
  # or auth method later reaches existing apps instead of silently skipping them.
  def change do
    alter table(:apps) do
      add :enabled_providers, {:array, :string}
      add :enabled_methods, {:array, :string}
      add :background_image_url, :string
      add :accent_color, :string
      add :email_from_name, :string
    end
  end
end
