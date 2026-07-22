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
    - `{:client_credentials, client_id, client_secret}` → `{:ok, %{jwt: jwt}}` | `{:error, :invalid_client}`
  """

  use GenServer

  alias You.JWT
  alias You.Repo
  alias You.Accounts
  alias You.Admin.App

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

  Pass `code_verifier` when the code was issued with a PKCE challenge; it must
  satisfy `base64url(sha256(code_verifier)) == code_challenge`.

  Returns `{:ok, %{user_id, email, jwt, refresh_token}}` or `{:error, reason}`
  (`:invalid_grant` on PKCE failure).
  """
  def exchange_code(code, code_verifier \\ nil) do
    GenServer.call(__MODULE__, {:exchange_code, code, code_verifier})
  end

  @doc """
  Rotates a refresh token for a new JWT + refresh token.
  Returns `{:ok, %{user_id, email, jwt, refresh_token}}` or `{:error, :invalid}`.
  """
  def refresh(refresh_token) do
    GenServer.call(__MODULE__, {:refresh, refresh_token})
  end

  @doc """
  Client-credentials (M2M) grant. Verifies the app slug and secret, and on
  success issues a service JWT with `type: "service"` and no user identity.

  Returns `{:ok, %{jwt: jwt}}` or `{:error, :invalid_client}`.
  """
  def client_credentials(client_id, client_secret)
      when is_binary(client_id) and is_binary(client_secret) do
    GenServer.call(__MODULE__, {:client_credentials, client_id, client_secret})
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
  def handle_call({:exchange_code, code}, from, state) do
    # Backward-compatible with pre-PKCE clients that send the 2-tuple message.
    handle_call({:exchange_code, code, nil}, from, state)
  end

  def handle_call({:exchange_code, code, code_verifier}, _from, state) do
    result =
      case Accounts.consume_auth_code(code, code_verifier) do
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

  @doc false
  def handle_call({:client_credentials, client_id, client_secret}, _from, state) do
    result =
      case Repo.get_by(App, slug: client_id) do
        nil ->
          :telemetry.execute(
            [:you, :audit, :token, :client_credentials],
            %{},
            %{result: :failure, reason: :unknown_client}
          )

          {:error, :invalid_client}

        %App{client_secret_hash: nil} ->
          :telemetry.execute(
            [:you, :audit, :token, :client_credentials],
            %{},
            %{result: :failure, reason: :no_secret}
          )

          {:error, :invalid_client}

        %App{client_secret_hash: hash, slug: slug} ->
          if :crypto.hash_equals(hash, :crypto.hash(:sha256, client_secret)) do
            jwt_expiry = You.Settings.get(:jwt_expiry_hours) * 3600

            {:ok, jwt} =
              JWT.sign(%{sub: slug, app: "you", type: "service"}, jwt_expiry)

            :telemetry.execute([:you, :audit, :token, :client_credentials], %{}, %{
              client_id: slug,
              result: :success
            })

            {:ok, %{jwt: jwt}}
          else
            :telemetry.execute(
              [:you, :audit, :token, :client_credentials],
              %{},
              %{result: :failure, reason: :invalid_secret}
            )

            {:error, :invalid_client}
          end
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
