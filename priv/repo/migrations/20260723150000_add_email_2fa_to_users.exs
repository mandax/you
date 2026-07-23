defmodule You.Repo.Migrations.AddEmail2faToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email_2fa_enabled, :boolean, null: false, default: false
    end
  end
end
