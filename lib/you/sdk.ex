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

  @doc """
  Headless password login for a trusted first-party app: authenticate the end
  user directly (no browser redirect / no You UI) and get a token bundle back.

  `creds` is a map with `email`, `password`, optional `scope`/`scopes`, and
  optional `totp_code`. The app authenticates itself with `client_id` +
  `client_secret` and must be flagged first-party in You.

  Returns `{:ok, %{user_id, email, jwt, refresh_token}}` or `{:error, reason}`
  (`:invalid_client` | `:not_first_party` | `:invalid_credentials` |
  `:mfa_required` | `:invalid_mfa` | `:unreachable`).
  """
  def password_login(client_id, client_secret, creds, opts \\ []) do
    call({:password_login, client_id, client_secret, creds}, opts)
  end

  @doc """
  Exchanges an authorization code for a JWT.

  For PKCE, pass the `:code_verifier` option matching the `code_challenge` sent
  at authorize time.

  Returns `{:ok, %{user_id, email, jwt}}` or `{:error, reason | :unreachable}`
  (`:invalid_grant` on PKCE failure).
  """
  def exchange_code(code, opts \\ []) do
    call({:exchange_code, code, opts[:code_verifier]}, opts)
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
