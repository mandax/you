defmodule You.IAM.Server do
  @moduledoc """
  GenServer that handles Erlang distribution messages from consumer apps.

  Registered as `You.IAM.Server`. Apps send messages via:

      GenServer.call({You.IAM.Server, you_node}, {:verify_token, jwt})

  Supported messages:

    - `{:verify_token, jwt}` → `{:ok, %{user_id, email, role}}` | `{:error, reason}`
    - `{:get_user, user_id}` → `{:ok, %{id, email}}` | `{:error, :not_found}`
    - `{:revoke_token, jwt}` → `:ok`
    - `{:exchange_code, code}` / `{:exchange_code, code, code_verifier}` →
      `{:ok, %{user_id, email, jwt, refresh_token}}` | `{:error, reason}`
    - `{:refresh, refresh_token}` →
      `{:ok, %{user_id, email, jwt, refresh_token}}` | `{:error, :invalid}`
    - `{:client_credentials, client_id, client_secret}` →
      `{:ok, %{jwt: jwt}}` | `{:error, :invalid_client}`
    - `{:password_login, client_id, client_secret, params}` →
      `{:ok, %{user_id, email, jwt, refresh_token}}` | `{:error, reason}`
      (first-party apps only)
    - `{:register, client_id, client_secret, params}` →
      `{:ok, %{user_id, email, jwt, refresh_token}}` | `{:error, reason}`
      (first-party apps only)
  """

  use GenServer

  alias You.JWT
  alias You.Repo
  alias You.Accounts
  alias You.Admin.App
  alias You.IAM.Claims

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

  @doc """
  Headless password login for a trusted **first-party** app: authenticates the
  end user directly and returns a token bundle: no browser redirect, no You
  login page, so the consumer app owns the whole experience ("invisible You").

  `params` is a map (atom or string keys) with `email`, `password`, optional
  `scopes` (list or space string), and optional `totp_code` for MFA.

  Returns `{:ok, %{user_id, email, jwt, refresh_token}}` or `{:error, reason}`
  where reason is `:invalid_client` | `:not_first_party` | `:invalid_credentials`
  | `:mfa_required` | `:invalid_mfa`. Only apps flagged `first_party` may use
  this; third-party apps must go through the redirect + consent flow.
  """
  def password_login(client_id, client_secret, params)
      when is_binary(client_id) and is_binary(client_secret) and is_map(params) do
    GenServer.call(__MODULE__, {:password_login, client_id, client_secret, params})
  end

  @doc """
  Headless registration (sign-up) for a trusted **first-party** app: creates a
  new user with the given email + password and returns a token bundle, so the
  consumer app owns the whole sign-up experience ("invisible You").

  The created user is **unconfirmed** (`confirmed_at: nil`) because the email is
  not yet verified at sign-up.  `params` is a map (atom or string keys) with
  `email`, `password`, and optional `scopes` (list or space string).

  Returns `{:ok, %{user_id, email, jwt, refresh_token}}` or `{:error, reason}`
  where reason is `:invalid_client` | `:not_first_party` |
  `:email_taken` | `:invalid_registration`.  Only apps flagged `first_party`
  may use this; third-party apps must go through the redirect + consent flow.
  """
  def register(client_id, client_secret, params)
      when is_binary(client_id) and is_binary(client_secret) and is_map(params) do
    GenServer.call(__MODULE__, {:register, client_id, client_secret, params})
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
        {:ok, user, scopes, app_slug} ->
          scopes = scopes || ["email"]

          :telemetry.execute(
            [:you, :audit, :token, :exchange],
            %{},
            %{user_id: user.id, scopes: scopes}
          )

          {:ok,
           token_bundle(
             user,
             scopes,
             Accounts.create_refresh_token(user, scopes, app_slug),
             app_slug
           )}

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
        {:ok, user, scopes, new_refresh, app_slug} ->
          scopes = scopes || ["email"]

          :telemetry.execute([:you, :audit, :token, :refresh], %{}, %{user_id: user.id})

          {:ok, token_bundle(user, scopes, new_refresh, app_slug)}

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

  @doc false
  def handle_call({:password_login, client_id, client_secret, params}, _from, state) do
    scopes = normalize_scopes(params)

    result =
      with {:ok, _app} <- verify_first_party_client(client_id, client_secret),
           {:ok, user} <- authenticate_credentials(params),
           :ok <- verify_login_mfa(user, params) do
        refresh = Accounts.create_refresh_token(user, scopes, client_id)

        :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
          user_id: user.id,
          email: user.email,
          method: "headless:#{client_id}",
          result: :success
        })

        {:ok, token_bundle(user, scopes, refresh, client_id)}
      end

    with {:error, reason} <- result do
      :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
        method: "headless:#{client_id}",
        result: :failure,
        reason: reason
      })
    end

    {:reply, result, state}
  end

  @doc false
  def handle_call({:register, client_id, client_secret, params}, _from, state) do
    email = params[:email] || params["email"]
    password = params[:password] || params["password"]
    scopes = normalize_scopes(params)

    result =
      with {:ok, _app} <- verify_first_party_client(client_id, client_secret),
           {:ok, user} <- create_user(email, password) do
        refresh = Accounts.create_refresh_token(user, scopes, client_id)

        :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
          user_id: user.id,
          email: user.email,
          method: "headless-register:#{client_id}",
          result: :success
        })

        {:ok, token_bundle(user, scopes, refresh, client_id)}
      end

    with {:error, reason} <- result do
      :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
        method: "headless-register:#{client_id}",
        result: :failure,
        reason: reason
      })
    end

    {:reply, result, state}
  end

  # Creates a user with the given email and password inside a transaction.
  # The user is created unconfirmed (confirmed_at nil). Returns
  # `{:ok, user}` or `{:error, :email_taken | :invalid_registration}`.
  defp create_user(email, password) do
    Repo.transact(fn ->
      with {:ok, user} <- Accounts.register_user(%{email: email}),
           {:ok, {user, _tokens}} <- Accounts.update_user_password(user, %{password: password}) do
        {:ok, user}
      else
        {:error, changeset} ->
          reason =
            if Enum.any?(changeset.errors, fn
                 {:email, {"has already been taken", _}} -> true
                 _ -> false
               end),
               do: :email_taken,
               else: :invalid_registration

          {:error, reason}
      end
    end)
  end

  # Verifies the app slug + secret AND that the app is trusted first-party.
  defp verify_first_party_client(client_id, client_secret) do
    case verify_client_secret(client_id, client_secret) do
      {:ok, %App{first_party: true} = app} -> {:ok, app}
      {:ok, %App{}} -> {:error, :not_first_party}
      error -> error
    end
  end

  # Constant-time app secret check.
  defp verify_client_secret(client_id, client_secret) do
    case Repo.get_by(App, slug: client_id) do
      %App{client_secret_hash: hash} = app when is_binary(hash) ->
        if is_binary(client_secret) and
             :crypto.hash_equals(hash, :crypto.hash(:sha256, client_secret)),
           do: {:ok, app},
           else: {:error, :invalid_client}

      _ ->
        {:error, :invalid_client}
    end
  end

  defp authenticate_credentials(params) do
    email = params[:email] || params["email"]
    password = params[:password] || params["password"]

    case Accounts.get_user_by_email_and_password(email, password) do
      nil -> {:error, :invalid_credentials}
      user -> {:ok, user}
    end
  end

  defp verify_login_mfa(%{totp_enabled: true} = user, params) do
    case params[:totp_code] || params["totp_code"] do
      code when is_binary(code) and code != "" ->
        if Accounts.verify_totp(user, code), do: :ok, else: {:error, :invalid_mfa}

      _ ->
        {:error, :mfa_required}
    end
  end

  defp verify_login_mfa(_user, _params), do: :ok

  defp normalize_scopes(params) do
    case params[:scopes] || params["scopes"] || params[:scope] || params["scope"] do
      list when is_list(list) -> list
      str when is_binary(str) -> String.split(str, " ", trim: true)
      _ -> ["email"]
    end
  end

  # Signs a scoped JWT and returns the token bundle handed back to consumers.
  defp token_bundle(user, scopes, refresh_token, app_slug) do
    jwt_expiry = You.Settings.get(:jwt_expiry_hours) * 3600
    {:ok, jwt} = JWT.sign(Claims.build_scoped_claims(user, scopes, app_slug), jwt_expiry)
    %{user_id: user.id, email: user.email, jwt: jwt, refresh_token: refresh_token}
  end
end
