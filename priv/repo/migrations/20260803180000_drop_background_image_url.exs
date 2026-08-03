defmodule You.Repo.Migrations.DropBackgroundImageUrl do
  @moduledoc """
  Drops `apps.background_image_url`.

  The column was only ever read by the console's own branding preview — the
  real login page never rendered it — so it was a control that promised
  something the product did not do. SQLite has supported `DROP COLUMN` since
  3.35; this project's own tooling and the release image are well past that.
  """
  use Ecto.Migration

  def up do
    alter table(:apps) do
      remove :background_image_url
    end
  end

  def down do
    alter table(:apps) do
      add :background_image_url, :string
    end
  end
end
