defmodule You.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :you

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @doc """
  Bootstraps the first admin user. Run via:

      bin/you eval 'You.Release.bootstrap_admin("admin@example.com", "password")'
  """
  def bootstrap_admin(email, password) do
    load_app()
    migrate()

    case You.Admin.bootstrap_admin(email, password) do
      {:ok, %{is_admin: true}} ->
        IO.puts("Admin user created successfully.")

      {:ok, %{email: ^email}} ->
        IO.puts("User #{email} is already an admin.")

      {:error, changeset} ->
        IO.puts("Failed to create admin: #{inspect(changeset.errors)}")
        System.halt(1)
    end
  end

  @doc """
  Configuration bundles from a release, where Mix is not installed:

      bin/you eval 'You.Release.export_bundle("/data/you/config.you-bundle")'
      bin/you eval 'You.Release.preview_bundle("/data/you/config.you-bundle")'
      bin/you eval 'You.Release.import_bundle("/data/you/config.you-bundle")'

  The password comes from `YOU_BUNDLE_PASSWORD_FILE`, `YOU_BUNDLE_PASSWORD`,
  or a prompt — never from the command line, which `bin/you eval` puts in
  shell history along with everything else. `bin/you eval` runs in its own VM
  with no terminal attached in most deployments, so set one of the two
  environment variables there.
  """
  def export_bundle(path, opts \\ []) do
    start_app()
    report(You.Config.CLI.export(path, opts), &"Wrote #{&1}.")
  end

  @doc "Reports what `import_bundle/2` would change. See `export_bundle/2`."
  def preview_bundle(path, opts \\ []) do
    start_app()

    report(
      You.Config.CLI.preview(path, opts),
      &"Would change #{You.Config.CLI.describe_summary(&1)}."
    )
  end

  @doc "Applies a bundle to this instance. See `export_bundle/2`."
  def import_bundle(path, opts \\ []) do
    start_app()

    report(
      You.Config.CLI.import(path, opts),
      &"Imported #{You.Config.CLI.describe_summary(&1)}."
    )
  end

  defp report({:ok, result}, message) do
    IO.puts(message.(result))
    :ok
  end

  defp report({:error, reason}, _message) do
    IO.puts(:stderr, You.Config.CLI.describe_error(reason))
    System.halt(1)
  end

  defp start_app do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
