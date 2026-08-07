defmodule Mix.Tasks.You.AuditHostnameLabels do
  @moduledoc """
  Reports apps whose `hostname_label`, rendered through the currently
  configured `APP_HOSTNAME_TEMPLATE`, would produce this instance's own
  canonical host — a takeover of the front door, not a naming collision.

  ## Usage

      mix you.audit_hostname_labels

  `You.Admin.App.changeset/2` refuses this at write time, but only against
  whatever the template and `PHX_HOST` were when that write happened. A
  label accepted before a template was configured, or before `PHX_HOST` was
  renamed to what the label now matches, is never re-checked — the same gap
  `mix you.audit_slugs` closes for `slug` (#119), for the same reason: the
  write-time guard cannot see a collision that did not exist yet.

  Run this after configuring or changing `APP_HOSTNAME_TEMPLATE`, and after
  renaming `PHX_HOST`. This task only reports; it does not clear or rename
  anything — a colliding label has to be changed with the same care as any
  other hostname change, since it is what the app is currently reachable at
  if the collision has not yet been triggered by a deploy.

  Exits with status 1 when it finds anything, so a deploy script can gate on
  it; exits 0 when nothing collides (including when no template is
  configured at all, in which case nothing can).

  In a release, where Mix is not installed, this is
  `bin/you eval 'You.Release.audit_hostname_labels()'`.
  """

  use Mix.Task

  alias You.Admin

  @shortdoc "Report apps whose hostname_label would take over the canonical host"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    report(Admin.apps_with_colliding_hostname_label())
  end

  defp report([]) do
    Mix.shell().info([:green, "No app hostname_label collides with the canonical host."])
  end

  defp report(apps) do
    Mix.shell().error(
      "#{length(apps)} app(s) have a hostname_label that resolves to this instance's " <>
        "own canonical host under the current APP_HOSTNAME_TEMPLATE:\n"
    )

    Enum.each(apps, fn app ->
      Mix.shell().info("  - #{app.hostname_label} (#{app.name}, id #{app.id})")
    end)

    Mix.shell().info([
      "\n",
      :yellow,
      "Each of these apps would answer as the instance's own front door — clear or ",
      "rename the hostname_label (PATCH /api/v1/apps/:id, or the app's own console ",
      "page) before enabling or changing APP_HOSTNAME_TEMPLATE for real traffic."
    ])

    exit({:shutdown, 1})
  end
end
