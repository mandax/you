defmodule You.IAM.Client do
  @moduledoc """
  Client for communicating with the You IAM Server via Erlang distribution.

  Consumer apps (Sockeet, future services) use this module to validate tokens,
  look up users, and revoke tokens. The module handles unreachable nodes
  gracefully, returning `{:error, :unreachable}` when You is down.

  ## Usage (from a consumer app on a connected node)

      # Verify a JWT issued by You
      You.IAM.Client.verify_token(jwt)

      # Look up a user by ID
      You.IAM.Client.get_user(42)

      # Revoke a JWT
      You.IAM.Client.revoke_token(jwt)

  ## Configuration in consumer app

      config :you_iam_client,
        node: :you@localhost,
        timeout: 5_000

  If `node` is not configured or is the local node, calls go direct to the
  local GenServer (for dev/test on a single node).
  """

  @default_timeout 5_000

  @doc """
  Validates a JWT by calling the IAM Server.

  Returns `{:ok, %{user_id: integer, email: string, role: string}}` on success,
  `{:error, reason}` on failure, or `{:error, :unreachable}` if You is down.
  """
  def verify_token(jwt, opts \\ []) do
    call({:verify_token, jwt}, opts)
  end

  @doc """
  Looks up a user by ID.

  Returns `{:ok, %{id: integer, email: string}}` or `{:error, :not_found}`
  or `{:error, :unreachable}`.
  """
  def get_user(user_id, opts \\ []) do
    call({:get_user, user_id}, opts)
  end

  @doc """
  Revokes a JWT. Returns `:ok` or `{:error, :unreachable}`.
  """
  def revoke_token(jwt, opts \\ []) do
    case call({:revoke_token, jwt}, opts) do
      :ok -> :ok
      error -> error
    end
  end

  defp call(msg, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    server = server_name()

    try do
      GenServer.call(server, msg, timeout)
    catch
      :exit, {:noproc, _} -> {:error, :unreachable}
      :exit, {:timeout, _} -> {:error, :unreachable}
      :exit, _reason -> {:error, :unreachable}
    end
  end

  defp server_name do
    case Application.get_env(:you_iam_client, :node) do
      nil -> You.IAM.Server
      node -> {You.IAM.Server, node}
    end
  end
end
