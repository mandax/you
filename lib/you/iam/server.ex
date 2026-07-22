defmodule You.IAM.Server do
  @moduledoc """
  GenServer that handles Erlang distribution messages from consumer apps
  (Sockeet, future services).

  Registered as `You.IAM.Server`. Apps send messages via:

      GenServer.call({You.IAM.Server, you_node}, {:verify_token, jwt})

  Supported messages:

    - `{:verify_token, jwt}` → `{:ok, %{user_id, email, role}}` | `{:error, reason}`
    - `{:get_user, user_id}` → `{:ok, %{id, email}}` | `{:error, :not_found}`
    - `{:revoke_token, jwt}` → `:ok`
  """

  use GenServer

  alias You.JWT
  alias You.Repo
  alias You.Accounts

  # Client

  @doc """
  Validates a JWT. Returns `{:ok, %{user_id, email, role}}` or `{:error, reason}`.
  """
  def verify_token(jwt) do
    GenServer.call(__MODULE__, {:verify_token, jwt})
  end

  @doc """
  Looks up a user by ID. Returns `{:ok, %{id, email}}` or `{:error, :not_found}`.
  """
  def get_user(user_id) do
    GenServer.call(__MODULE__, {:get_user, user_id})
  end

  @doc """
  Revokes a JWT. Returns `:ok`.
  """
  def revoke_token(jwt) do
    GenServer.call(__MODULE__, {:revoke_token, jwt})
  end

  @doc """
  Exchanges an authorization code for a JWT + refresh token.
  Returns `{:ok, %{user_id, email, jwt, refresh_token}}` or `{:error, reason}`.
  """
  def exchange_code(code) do
    GenServer.call(__MODULE__, {:exchange_code, code})
  end

  @doc """
  Rotates a refresh token for a new JWT + refresh token.
  Returns `{:ok, %{user_id, email, jwt, refresh_token}}` or `{:error, :invalid}`.
  """
  def refresh(refresh_token) do
    GenServer.call(__MODULE__, {:refresh, refresh_token})
  end

  # Server

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_call({:verify_token, jwt}, _from, state) do
    result =
      case JWT.verify(jwt) do
        {:ok, claims} ->
          user_id = claims["sub"]

          case Repo.get(Accounts.User, user_id) do
            %{email: email} when not is_nil(email) ->
              if String.starts_with?(email, "redacted-") do
                {:error, :not_found}
              else
                {:ok, %{user_id: user_id, email: claims["email"], role: claims["role"]}}
              end

            _ ->
              {:error, :not_found}
          end

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_user, user_id}, _from, state) do
    result =
      case Repo.get(Accounts.User, user_id) do
        %{email: email} when not is_nil(email) ->
          if String.starts_with?(email, "redacted-") do
            {:error, :not_found}
          else
            {:ok, %{id: user_id, email: email}}
          end

        _ ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:revoke_token, jwt}, _from, state) do
    JWT.revoke(jwt)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:exchange_code, code}, _from, state) do
    result =
      case Accounts.consume_auth_code(code) do
        {:ok, user, scopes} ->
          scopes = scopes || ["email"]

          :telemetry.execute(
            [:you, :audit, :token, :exchange],
            %{},
            %{user_id: user.id, scopes: scopes}
          )

          {:ok, token_bundle(user, scopes, Accounts.create_refresh_token(user, scopes))}

        {:error, reason} ->
          :telemetry.execute(
            [:you, :audit, :token, :exchange],
            %{},
            %{result: :failure, reason: reason}
          )

          {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:refresh, refresh_token}, _from, state) do
    result =
      case Accounts.rotate_refresh_token(refresh_token) do
        {:ok, user, scopes, new_refresh} ->
          scopes = scopes || ["email"]

          :telemetry.execute([:you, :audit, :token, :refresh], %{}, %{user_id: user.id})

          {:ok, token_bundle(user, scopes, new_refresh)}

        {:error, _reason} ->
          :telemetry.execute([:you, :audit, :token, :refresh], %{}, %{result: :failure})
          {:error, :invalid}
      end

    {:reply, result, state}
  end

  # Signs a scoped JWT and returns the token bundle handed back to consumers.
  defp token_bundle(user, scopes, refresh_token) do
    jwt_expiry = You.Settings.get(:jwt_expiry_hours) * 3600
    {:ok, jwt} = JWT.sign(build_scoped_claims(user, scopes), jwt_expiry)
    %{user_id: user.id, email: user.email, jwt: jwt, refresh_token: refresh_token}
  end

  defp build_scoped_claims(user, scopes) do
    base = %{sub: user.id, app: "you"}

    scopes
    |> Enum.reduce(base, fn
      "email", acc -> Map.put(acc, :email, user.email)
      "profile", acc -> acc |> Map.put(:email, user.email) |> Map.put(:name, user.email)
      "roles", acc -> acc |> Map.put(:email, user.email) |> Map.put(:role, user_role(user))
      _, acc -> acc
    end)
  end

  # Real role from the account's admin flag, so consumer apps (Sockeet) can gate
  # on it. A fuller role model (multiple named roles) is roadmap; this closes the
  # "role is always 'user'" gap that blocked admin authorization downstream.
  defp user_role(%{is_admin: true}), do: "admin"
  defp user_role(_), do: "user"
end
