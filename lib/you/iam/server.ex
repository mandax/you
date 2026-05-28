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
  Exchanges an authorization code for a JWT. Returns `{:ok, %{user_id, email, jwt}}` or `{:error, reason}`.
  """
  def exchange_code(code) do
    GenServer.call(__MODULE__, {:exchange_code, code})
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
          claims = build_scoped_claims(user, scopes || ["email"])

          jwt_expiry = You.Settings.get(:jwt_expiry_hours) * 3600
          {:ok, jwt} = JWT.sign(claims, jwt_expiry)

          :telemetry.execute(
            [:you, :audit, :token, :exchange],
            %{},
            %{user_id: user.id, scopes: scopes}
          )

          {:ok, %{user_id: user.id, email: user.email, jwt: jwt}}

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

  defp build_scoped_claims(user, scopes) do
    base = %{sub: user.id, app: "you"}

    scopes
    |> Enum.reduce(base, fn
      "email", acc -> Map.put(acc, :email, user.email)
      "profile", acc -> acc |> Map.put(:email, user.email) |> Map.put(:name, user.email)
      "roles", acc -> acc |> Map.put(:email, user.email) |> Map.put(:role, "user")
      _, acc -> acc
    end)
  end
end
