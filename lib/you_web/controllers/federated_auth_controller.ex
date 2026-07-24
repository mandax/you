defmodule YouWeb.FederatedAuthController do
  use YouWeb, :controller

  alias You.Accounts

  @doc """
  GET /auth/:provider

  Builds the upstream OIDC authorize URL and redirects the user.
  Stores the OIDC `state` param in the session for CSRF protection.
  """
  def authorize(conn, %{"provider" => provider}) do
    with {:ok, config} <- fetch_provider_config(provider) do
      state = generate_state()

      query =
        URI.encode_query(%{
          client_id: config.client_id,
          redirect_uri: redirect_uri(conn, provider),
          response_type: "code",
          scope: config.scopes,
          state: state
        })

      authorize_url = "#{config.authorize_url}?#{query}"

      conn
      |> put_session(:oidc_state, state)
      |> put_session(:oidc_provider, provider)
      |> redirect(external: authorize_url)
    else
      :error ->
        conn
        |> put_flash(:error, "Unknown authentication provider.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  GET /auth/:provider/callback

  Handles the OIDC callback: verifies state, exchanges the authorization
  code for tokens, fetches the userinfo, and logs the user in.
  """
  def callback(conn, %{"provider" => provider, "code" => code, "state" => state}) do
    with {:ok, config} <- fetch_provider_config(provider),
         :ok <- verify_state(conn, state),
         {:ok, tokens} <- exchange_code(config, code, conn, provider),
         {:ok, userinfo} <- fetch_userinfo(config, tokens),
         {:ok, user} <-
           Accounts.find_or_create_user_by_federated_identity(
             provider,
             userinfo["sub"],
             userinfo["email"],
             email_verified?(userinfo)
           ) do
      :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
        user_id: user.id,
        email: user.email,
        method: "oidc:#{provider}",
        result: :success
      })

      # Hand the login back to the requesting app (mint a code → consumer
      # callback) when this login was started from an OAuth flow; otherwise it's
      # a plain sign-in to You.
      conn
      |> put_session(:oidc_state, nil)
      |> put_session(:oidc_provider, nil)
      |> put_flash(:info, "Welcome back!")
      |> YouWeb.OAuthFlow.complete_login(user)
    else
      {:error, :state_mismatch} ->
        conn
        |> put_flash(:error, "Authentication failed: state mismatch.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :transaction_aborted} ->
        conn
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :email_not_verified} ->
        # The IdP didn't assert the email is verified, so we refuse to link it to
        # an existing account (takeover protection). The user must sign in with
        # their existing method and link the provider from account settings.
        :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
          method: "oidc:#{provider}",
          result: :failure,
          reason: :email_not_verified
        })

        conn
        |> put_flash(
          :error,
          "That #{provider} account's email isn't verified. Sign in with your existing method, then link #{provider} from settings."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, reason} ->
        :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
          method: "oidc:#{provider}",
          result: :failure,
          reason: reason
        })

        conn
        |> put_flash(:error, "Authentication failed: #{reason}")
        |> redirect(to: ~p"/users/log-in")

      :error ->
        conn
        |> put_flash(:error, "Authentication failed.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # -- Helpers

  # IdPs report the email_verified claim as a boolean or a string.
  defp email_verified?(userinfo) do
    case userinfo["email_verified"] do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp fetch_provider_config(provider) do
    providers = Application.get_env(:you, :oidc_providers, %{})

    case Map.fetch(providers, provider) do
      {:ok, config} ->
        config = Map.new(config, fn {k, v} -> {String.to_existing_atom(k), v} end)
        {:ok, config}

      :error ->
        :error
    end
  end

  defp generate_state do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp verify_state(conn, state) do
    stored = get_session(conn, :oidc_state)

    if is_binary(stored) and stored == state do
      :ok
    else
      {:error, :state_mismatch}
    end
  end

  defp redirect_uri(_conn, provider) do
    url(~p"/auth/#{provider}/callback")
  end

  defp exchange_code(config, code, conn, provider) do
    body = %{
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri(conn, provider),
      client_id: config.client_id,
      client_secret: config.client_secret
    }

    case Req.post(config.token_url, form: body) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "token endpoint returned #{status}"}

      {:error, %{reason: reason}} ->
        {:error, reason}
    end
  end

  defp fetch_userinfo(config, tokens) do
    access_token =
      cond do
        is_binary(tokens) -> tokens
        is_map(tokens) -> tokens["access_token"]
      end

    headers = [{"authorization", "Bearer #{access_token}"}]

    case Req.get(config.userinfo_url, headers: headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "userinfo endpoint returned #{status}"}

      {:error, %{reason: reason}} ->
        {:error, reason}
    end
  end
end
