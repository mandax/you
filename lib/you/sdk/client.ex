defmodule You.SDK.Client do
  @moduledoc false

  # HTTP client for You's REST API.
  # Used internally by You.SDK. Consumer apps can also use this directly.

  @default_timeout 5_000

  @doc false
  def post(base_url, path, body) do
    url = base_url <> path

    case Req.post(url, json: body, receive_timeout: @default_timeout) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %{status: 401, body: body}} ->
        {:error, Map.get(body, "error", :unauthorized)}

      {:ok, %{status: 204}} ->
        {:ok, nil}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, %{reason: reason}} ->
        {:error, {:http_error, reason}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc false
  def delete(base_url, path, jwt) do
    url = base_url <> path

    headers = [authorization: "Bearer #{jwt}"]

    case Req.delete(url, headers: headers, receive_timeout: @default_timeout) do
      {:ok, %{status: 204}} ->
        {:ok, nil}

      {:ok, %{status: status, body: body}} ->
        {:error, Map.get(body, "error", {:unexpected_status, status})}

      {:error, %{reason: reason}} ->
        {:error, {:http_error, reason}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc false
  def get(base_url, path) do
    url = base_url <> path

    case Req.get(url, receive_timeout: @default_timeout) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, %{reason: reason}} ->
        {:error, {:http_error, reason}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end
end
