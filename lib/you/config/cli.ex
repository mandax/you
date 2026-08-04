defmodule You.Config.CLI do
  @moduledoc """
  Command-line entry points for configuration bundles, shared by
  `Mix.Tasks.You.Bundle` and `You.Release`.

  Configuration should be scriptable, not only clickable: CI promoting a
  staging configuration to production, backup automation that does not depend
  on someone clicking, support scripting. Disaster recovery is exactly when the
  console may be the thing that is unavailable, which is why the command line
  matters at least as much as the HTTP API.

  ## The password never comes from argv

  A password on a command line lands in shell history, in `ps` output, and in
  CI logs. It is resolved, in order, from:

    1. `:password_file` (or `YOU_BUNDLE_PASSWORD_FILE`) — the file's contents,
       trimmed. The right answer for CI: a mounted secret, never a string in a
       job definition.
    2. `YOU_BUNDLE_PASSWORD` — for an operator who has already exported it into
       a shell they trust.
    3. An interactive prompt with echo off.

  There is deliberately no `--password` flag.
  """

  alias You.Config.Bundle
  alias You.Config.Vault

  @password_env "YOU_BUNDLE_PASSWORD"
  @password_file_env "YOU_BUNDLE_PASSWORD_FILE"

  @doc """
  Seals this instance's configuration and writes it to `path`.

  Returns `{:ok, path}` or `{:error, reason}`. Refuses to overwrite an
  existing file unless `:force` is set: a bundle is what someone restores
  from, and clobbering yesterday's during today's export is a bad afternoon.
  """
  def export(path, opts \\ []) do
    with :ok <- refuse_existing(path, opts),
         {:ok, password} <- password(opts, :confirm) do
      contents = Bundle.export() |> Vault.seal(password)

      case File.write(path, contents) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, {:write_failed, path, reason}}
      end
    end
  end

  @doc """
  Reports what importing the bundle at `path` would change, without writing.

  Returns `{:ok, preview}`; see `You.Config.Bundle.preview/1`.
  """
  def preview(path, opts \\ []) do
    with {:ok, payload} <- open_bundle(path, opts) do
      Bundle.preview(payload)
    end
  end

  @doc """
  Applies the bundle at `path` to this instance.

  Returns `{:ok, summary}` with a count per section.
  """
  def import(path, opts \\ []) do
    with {:ok, payload} <- open_bundle(path, opts) do
      Bundle.import(payload)
    end
  end

  defp open_bundle(path, opts) do
    with {:ok, contents} <- read_bundle(path),
         {:ok, password} <- password(opts, :once) do
      Vault.open(contents, password)
    end
  end

  defp read_bundle(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp refuse_existing(path, opts) do
    if File.exists?(path) and not Keyword.get(opts, :force, false) do
      {:error, {:already_exists, path}}
    else
      :ok
    end
  end

  # `confirm` asks twice when prompting interactively: a typo in an export
  # password is only discovered when the bundle is needed, and by then the
  # bundle is unopenable. A password from a file or the environment is not
  # confirmed — there is nothing to mistype.
  defp password(opts, mode) do
    case resolve_password(opts) do
      {:ok, password} -> validate(password)
      {:error, _reason} = error -> error
      :prompt -> prompt(mode)
    end
  end

  defp resolve_password(opts) do
    file = Keyword.get(opts, :password_file) || System.get_env(@password_file_env)

    cond do
      is_binary(file) -> read_password_file(file)
      is_binary(System.get_env(@password_env)) -> {:ok, System.get_env(@password_env)}
      true -> :prompt
    end
  end

  defp read_password_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, String.trim(contents)}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp prompt(:once) do
    "Bundle password: " |> read_password() |> validate()
  end

  defp prompt(:confirm) do
    password = read_password("Bundle password: ")
    confirm = read_password("Confirm bundle password: ")

    if password == confirm do
      validate(password)
    else
      {:error, :password_mismatch}
    end
  end

  defp read_password(label) do
    IO.write(label)

    case :io.get_password() do
      {:ok, chars} ->
        IO.write("\n")
        chars |> List.to_string() |> String.trim()

      # No terminal to turn echo off on — a CI runner, or output piped
      # somewhere. Refusing here would be worse than the visible prompt the
      # bootstrap task already falls back to.
      {:error, _reason} ->
        IO.write("\n")
        IO.gets("") |> to_string() |> String.trim()
    end
  end

  defp validate(password) when is_binary(password) do
    if String.length(password) < Vault.min_password_length() do
      {:error, {:password_too_short, Vault.min_password_length()}}
    else
      {:ok, password}
    end
  end

  @doc """
  A one-line, human-readable rendering of any error these functions return.
  """
  def describe_error({:already_exists, path}),
    do: "#{path} already exists. Pass --force to overwrite it."

  def describe_error({:read_failed, path, reason}),
    do: "could not read #{path}: #{:file.format_error(reason)}"

  def describe_error({:write_failed, path, reason}),
    do: "could not write #{path}: #{:file.format_error(reason)}"

  def describe_error({:password_too_short, min}),
    do: "the bundle password must be at least #{min} characters"

  def describe_error(:password_mismatch), do: "the passwords do not match"

  def describe_error(:wrong_password),
    do: "wrong password, or the bundle has been altered since it was sealed"

  def describe_error(:malformed), do: "that file is not a You configuration bundle"

  def describe_error(:unsupported_version),
    do: "that bundle was written by a newer You than this one"

  def describe_error(reason), do: "import failed: #{inspect(reason)}"

  @doc """
  A one-line summary of what an import or preview touched, for printing.
  """
  def describe_summary(summary) do
    summary
    |> Map.take([:settings, :apps, :identity_providers, :webhook_endpoints])
    |> Enum.map(fn {section, value} -> "#{count(value)} #{section}" end)
    |> Enum.join(", ")
  end

  defp count(value) when is_integer(value), do: value
  defp count(value) when is_list(value), do: length(value)
  defp count(value) when is_map(value), do: map_size(value)
end
