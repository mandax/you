defmodule Mix.Tasks.You.AuditSlugs do
  @moduledoc """
  Reports apps whose slug violates the format `You.Admin.App.changeset/2`
  enforces: lowercase letters, digits, hyphens and underscores only, bounded
  in length.

  ## Usage

      mix you.audit_slugs

  Run this before upgrading to a version that validates `slug`: a row written
  earlier may already violate the rule, and once validation is enforced,
  every future update to that app — not just ones touching the slug — fails
  until it is fixed.

  This task only reports; it does not rename anything. **Renaming a slug
  changes the app's `client_id`**, since the slug is the client_id, and
  breaks every consumer configured against the old value. Coordinate a slug
  change with whoever operates each affected app before making it.
  """

  use Mix.Task

  alias You.Admin

  @shortdoc "Report apps whose slug violates the client_id format rule"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Admin.apps_with_invalid_slug() do
      [] ->
        Mix.shell().info([:green, "All app slugs satisfy the client_id format rule."])

      apps ->
        report(apps)
    end
  end

  defp report(apps) do
    Mix.shell().error(
      "#{length(apps)} app(s) have a slug that will fail validation once enforced:\n"
    )

    Enum.each(apps, fn app ->
      Mix.shell().info("  - #{app.slug} (#{app.name}, id #{app.id})")
    end)

    Mix.shell().info([
      "\n",
      :yellow,
      "Renaming a slug changes that app's client_id and breaks every consumer ",
      "configured against it. Coordinate with each app's operator before renaming."
    ])
  end
end
