defmodule Mix.Tasks.You.Bundle do
  @moduledoc """
  Exports, previews and imports encrypted configuration bundles.

  ## Usage

      mix you.bundle export config.you-bundle [--force]
      mix you.bundle preview config.you-bundle
      mix you.bundle import  config.you-bundle

  The password is read from `YOU_BUNDLE_PASSWORD_FILE`, then
  `YOU_BUNDLE_PASSWORD`, then an interactive prompt — never from the command
  line, where it would land in shell history and `ps` output. See
  `You.Config.CLI`.

  In a release, where Mix is not installed, the same three commands are
  `bin/you eval 'You.Release.export_bundle("…")'` and friends.

  A bundle carries settings, apps, identity providers and webhook endpoints —
  never users, tokens, sessions or consents. It is configuration, not a
  database backup. Instance identity (`erlang_cookie`, `api_token`,
  `scim_bearer_token`) is refused in both directions.
  """

  use Mix.Task

  alias You.Config.CLI

  @shortdoc "Export, preview or import a configuration bundle"

  @switches [force: :boolean, password_file: :string]

  @impl Mix.Task
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.start")

    case positional do
      ["export", path] -> report(CLI.export(path, opts), &"Wrote #{&1}.")
      ["preview", path] -> report(CLI.preview(path, opts), &preview_message/1)
      ["import", path] -> report(CLI.import(path, opts), &"Imported #{CLI.describe_summary(&1)}.")
      _ -> usage()
    end
  end

  defp report({:ok, result}, message) do
    Mix.shell().info([:green, message.(result)])
  end

  defp report({:error, reason}, _message) do
    Mix.shell().error(CLI.describe_error(reason))
    exit({:shutdown, 1})
  end

  defp preview_message(preview) do
    ignored =
      case preview.ignored_settings do
        [] -> ""
        keys -> "\nIgnored (instance identity): #{Enum.join(keys, ", ")}."
      end

    "Would change #{CLI.describe_summary(preview)}." <> ignored
  end

  defp usage do
    Mix.shell().error("""
    Usage:
      mix you.bundle export <path> [--force]
      mix you.bundle preview <path>
      mix you.bundle import <path>
    """)

    exit({:shutdown, 1})
  end
end
