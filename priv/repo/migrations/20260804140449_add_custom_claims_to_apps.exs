defmodule You.Repo.Migrations.AddCustomClaimsToApps do
  @moduledoc """
  Static extra claims an app wants in the JWTs issued for it — a tenant id, a
  plan, a feature flag — so the app can read them from the token instead of
  making a second round-trip to fetch them.

  A JSON object on the app row. NULL and `{}` both mean "no extra claims".
  """
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :custom_claims, :map
    end
  end
end
