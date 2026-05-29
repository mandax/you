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

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
