defmodule You.Accounts.PwnedPasswords do
  @moduledoc """
  Checks a password against Have I Been Pwned's Pwned Passwords range API using
  k-anonymity: only the first five hex chars of the password's SHA-1 are sent,
  never the password or its full hash. The API returns every suffix under that
  prefix with a breach count; we match ours locally.

  Fails open by design: a network error means "unknown", not "blocked", so an
  HIBP outage never stops a user from setting a password.
  """
  require Logger

  @endpoint "https://api.pwnedpasswords.com/range/"

  @doc """
  How many known breaches this password appears in. `{:ok, 0}` means clean;
  `{:error, reason}` means the check couldn't run (treat as unknown).
  """
  @spec breach_count(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def breach_count(password) when is_binary(password) do
    <<prefix::binary-size(5), suffix::binary>> =
      :crypto.hash(:sha, password) |> Base.encode16(case: :upper)

    case Req.get(@endpoint <> prefix,
           receive_timeout: 3_000,
           retry: false,
           headers: [{"add-padding", "true"}]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, count_in_response(body, suffix)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("[PwnedPasswords] check failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Parses a range-API response body (`SUFFIX:COUNT` lines) for the given suffix.
  Public so it can be tested without a network call.
  """
  @spec count_in_response(String.t(), String.t()) :: non_neg_integer()
  def count_in_response(body, suffix) do
    body
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [hash_suffix, count] ->
          if String.upcase(hash_suffix) == suffix, do: parse_count(count)

        _ ->
          nil
      end
    end)
  end

  defp parse_count(count) do
    case Integer.parse(String.trim(count)) do
      {n, _} -> n
      :error -> 0
    end
  end
end
