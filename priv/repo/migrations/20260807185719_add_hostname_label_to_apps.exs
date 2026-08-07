defmodule You.Repo.Migrations.AddHostnameLabelToApps do
  use Ecto.Migration

  # Nullable, and empty by default — never auto-filled from `slug`. Unlike
  # `slug` (the OAuth client_id), this is a cosmetic hostname component: an
  # app with no label has no hostname of its own and keeps sharing the
  # canonical host, exactly as every app does today. See `You.Admin.App` for
  # the format and uniqueness rules enforced at write time (#121).
  def change do
    alter table(:apps) do
      add :hostname_label, :string
    end

    create unique_index(:apps, [:hostname_label])
  end
end
