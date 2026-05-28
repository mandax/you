defmodule Mix.Tasks.You.BootstrapAdmin do
  @moduledoc """
  Creates the first admin user interactively.

  ## Usage

      mix you.bootstrap_admin

  Prompts for email and password. Idempotent — if the user is already
  an admin, prints a message and exits.
  """

  use Mix.Task

  @shortdoc "Create the first admin user"

  def run(_args) do
    Mix.shell().info([:green, "=== You Admin Bootstrap ==="])
    Mix.shell().info("Creates the first admin user for the You IAM instance.")

    email = IO.gets("Email: ") |> String.trim()

    IO.write("Password: ")
    password = read_password()

    IO.write("Confirm password: ")
    confirm = read_password()

    if password != confirm do
      Mix.shell().error("Passwords do not match.")
      exit({:shutdown, 1})
    end

    min_length = if Mix.env() == :dev, do: 6, else: 12

    if byte_size(password) < min_length do
      Mix.shell().error("Password must be at least #{min_length} characters.")
      exit({:shutdown, 1})
    end

    # Ensure ecto repos are started
    Mix.Task.run("app.start")

    case You.Admin.bootstrap_admin(email, password) do
      {:ok, %{is_admin: true}} ->
        Mix.shell().info([:green, "Admin user created successfully."])

      {:ok, %{email: ^email}} ->
        Mix.shell().info([:yellow, "User #{email} is already an admin."])

      {:error, changeset} ->
        Mix.shell().error("Failed to create admin: #{inspect(changeset.errors)}")
        exit({:shutdown, 1})
    end
  end

  defp read_password do
    case :io.get_password() do
      {:ok, chars} ->
        IO.write("\n")
        List.to_string(chars)

      {:error, _} ->
        IO.write("\n")
        Mix.shell().prompt("Password: ")
    end
  end
end
