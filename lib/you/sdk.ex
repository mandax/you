defmodule You.SDK do
  @moduledoc """
  SDK for integrating apps with the You IAM service via Erlang distribution.

  Consumer apps add this as a dependency and call these functions. They communicate
  with You's `You.IAM.Server` GenServer over Erlang distribution — no HTTP needed.

  ## Usage in a consumer app (on a connected Erlang node)

      # Verify a JWT
      You.SDK.verify_token(jwt, node: :"you@host")
      # => {:ok, %{user_id: 1, email: "...", role: "user"}}

      # Look up a user
      You.SDK.get_user(42, node: :"you@host")
      # => {:ok, %{id: 42, email: "..."}}

      # Revoke a session
      You.SDK.revoke_token(jwt, node: :"you@host")

  ## Configuration

      config :you_sdk, node: :"you@you.internal"

  Calling with an explicit `node:` option overrides the configured default.
  If no node is configured and none is passed, calls go to the local node
  (for development when You and the app run in the same Elixir instance).
  """

  @default_timeout 5_000

  @doc """
  Validates a JWT against You's IAM Server.

  Returns `{:ok, %{user_id, email, role}}` or `{:error, reason}`.
  """
  def verify_token(jwt, opts \\ []) do
    call({:verify_token, jwt}, opts)
  end

  @doc """
  Looks up a user by ID.

  Returns `{:ok, %{id, email}}` or `{:error, :not_found}`.
  """
  def get_user(user_id, opts \\ []) do
    call({:get_user, user_id}, opts)
  end

  @doc """
  Revokes a JWT. Returns `:ok`.
  """
  def revoke_token(jwt, opts \\ []) do
    call({:revoke_token, jwt}, opts)
  end

  defp call(msg, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    server = Keyword.get(opts, :node) || Application.get_env(:you_sdk, :node)

    target = if server, do: {You.IAM.Server, server}, else: You.IAM.Server

    try do
      GenServer.call(target, msg, timeout)
    catch
      :exit, {:noproc, _} -> {:error, :unreachable}
      :exit, {:timeout, _} -> {:error, :unreachable}
      :exit, _ -> {:error, :unreachable}
    end
  end
end
