defmodule Mix.Tasks.You.AuditSlugs do
  @moduledoc """
  Reports apps whose slug violates a rule `You.Admin.App.changeset/2`
  enforces: the format (lowercase letters, digits, hyphens and underscores
  only), the length bound, or reservation — `new`, which `/console/apps/new`
  (#130) claims ahead of the per-app page.

  ## Usage

      mix you.audit_slugs

  Run this right after upgrading to a version that validates `slug`, before
  renaming anything. A row written earlier keeps its non-conforming slug
  until something touches the slug itself, but from here on: renaming such
  an app fails validation, and importing a configuration bundle that carries
  one from a pre-validation instance **silently skips that app** — the import
  reports success with a count one short, because the import counts successes
  rather than surfacing a rejected changeset. The non-conforming value is
  already live everywhere a slug is used — the `client_id` a consumer configures,
  authorize URLs, and the role-resolution key — so this is the moment to
  find out which apps are affected, not a hard deadline.

  This task only reports; it does not rename anything. **Renaming a slug
  changes the app's `client_id`** — the only way to do it is
  `PATCH /api/v1/apps/:id` — and breaks every consumer configured against
  the old value. Coordinate with whoever runs each consumer app before
  making that change.

  Exits with status 1 when it finds anything, so a deploy script can gate on
  it; exits 0 when every slug already satisfies the rule.

  In a release, where Mix is not installed, this is
  `bin/you eval 'You.Release.audit_slugs()'`.
  """

  use Mix.Task

  alias You.Admin

  @shortdoc "Report apps whose slug violates the client_id format or reservation rules"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    report(Admin.apps_with_invalid_slug())
  end

  defp report([]) do
    Mix.shell().info([:green, "All app slugs satisfy the client_id rules."])
  end

  defp report(apps) do
    Mix.shell().error(
      "#{length(apps)} app(s) have a slug that fails a client_id rule (format, length, or reservation):\n"
    )

    Enum.each(apps, fn app ->
      Mix.shell().info("  - #{app.slug} (#{app.name}, id #{app.id})")
    end)

    Mix.shell().info([
      "\n",
      :yellow,
      "Renaming a slug changes that app's client_id and breaks every consumer ",
      "configured against it — PATCH /api/v1/apps/:id is the only way to change ",
      "it. Coordinate with whoever runs each consumer app before renaming. ",
      "If a listed slug is a reserved name (`new`), it is also unreachable at ",
      "/console/apps/<slug> specifically — that path now resolves to the page ",
      "the reservation protects, not this app."
    ])

    exit({:shutdown, 1})
  end
end
