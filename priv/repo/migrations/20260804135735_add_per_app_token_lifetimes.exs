defmodule You.Repo.Migrations.AddPerAppTokenLifetimes do
  @moduledoc """
  Per-app overrides for the two token lifetimes that are an app's decision.

  NULL means "follow the instance setting", the same convention
  `enabled_providers` and `enabled_methods` already use, so an existing app
  keeps behaving exactly as it did and a later change to the instance default
  still reaches it.

  `session_expiry_hours` deliberately gets no column: that is the You portal
  cookie, one per browser across every app, so it has no app to belong to.
  """
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :jwt_expiry_hours, :integer
      add :code_expiry_minutes, :integer
    end
  end
end
