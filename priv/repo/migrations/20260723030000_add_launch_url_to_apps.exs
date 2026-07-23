defmodule You.Repo.Migrations.AddLaunchUrlToApps do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :launch_url, :string
    end
  end
end
