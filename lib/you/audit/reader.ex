defmodule You.Audit.Reader do
  @moduledoc """
  Reads and filters audit log files.

  Files are newline-delimited JSON stored in the configured log directory.
  """

  @doc """
  Returns the log directory path.
  """
  def log_dir do
    :persistent_term.get({You.Audit.Handler, :log_dir})
  rescue
    _ -> Application.get_env(:you, :audit, [])[:log_dir] || "priv/log"
  end

  @doc """
  Lists available log categories.
  """
  def categories do
    dir = log_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&String.replace_suffix(&1, ".jsonl", ""))

      {:error, _} ->
        []
    end
  end

  @doc """
  Reads the last N events from a category file.
  Returns a list of parsed event maps, newest first.
  """
  def read(category, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    file_path = Path.join(log_dir(), "#{category}.jsonl")

    case File.read(file_path) do
      {:ok, content} ->
        content
        |> String.trim()
        |> String.split("\n")
        |> Enum.reverse()
        |> Enum.take(limit)
        |> Enum.map(&parse_line/1)
        |> Enum.filter(& &1)

      {:error, _} ->
        []
    end
  end

  defp parse_line(line) do
    case Jason.decode(line) do
      {:ok, event} -> event
      {:error, _} -> nil
    end
  end
end
