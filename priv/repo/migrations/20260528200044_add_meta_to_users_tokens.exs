defmodule You.Repo.Migrations.AddMetaToUsersTokens do
  use Ecto.Migration

  def change do
    alter table(:users_tokens) do
      add :meta, :text
    end
  end
end
