defmodule YouWeb.FederatedAuthController do
  use YouWeb, :controller

  import YouWeb.AuthMethods, only: [app_for: 1, enabled?: 2]

  alias You.{Accounts, Admin, IdentityProviders}

  @doc """
  GET /auth/:provider

  Builds the upstream OIDC authorize URL and redirects the user.
  Stores the OIDC `state` param in the session for CSRF protection.
  """
  def authorize(conn, %{"provider" => provider}) do
    with {:ok, config} <- fetch_provider_config(provider),
         :ok <- authorize_for_app(conn, provider) do
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
         :ok <- authorize_for_app(conn, provider),
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
        result: :success,
        host: conn.host
      })

      # An identity provider proves the first factor only: an account with a
      # second factor enrolled still has to meet it. Past that, the login goes
      # back to the requesting app as an authorization code when this started
      # from an OAuth flow, and is otherwise a plain sign-in to You.
      conn
      |> put_session(:oidc_state, nil)
      |> put_session(:oidc_provider, nil)
      |> YouWeb.SecondFactor.complete_login(user, "Welcome back!")
    else
      {:error, :state_mismatch} ->
        conn
        |> put_flash(:error, "Authentication failed: state mismatch.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :transaction_aborted} ->
        conn
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :provider_misconfigured} ->
        conn
        |> put_flash(:error, "That provider is misconfigured.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :email_not_verified} ->
        # The IdP didn't assert the email is verified, so we refuse to link it to
        # an existing account (takeover protection). The user must sign in with
        # their existing method and link the provider from account settings.
        :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
          method: "oidc:#{provider}",
          result: :failure,
          reason: :email_not_verified,
          host: conn.host
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
          reason: reason,
          host: conn.host
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
    case IdentityProviders.get_provider_by_slug(provider) do
      {:ok, %{enabled: true} = config} -> {:ok, config}
      _ -> :error
    end
  end

  # A provider an app has not enabled must be rejected here, not merely
  # hidden from the login page — anyone can hit /auth/:provider directly.
  # `enabled_providers: nil` on the app means every provider is allowed;
  # a login with no in-flight app (not an OAuth handoff) is unrestricted too.
  #
  # The same two switches gate it as any other method: social login can be
  # turned off instance-wide via Settings, or per-app by omitting "social"
  # from the app's enabled_methods.
  defp authorize_for_app(conn, provider) do
    app = app_for(conn)

    if enabled?(conn, "social") and provider in Admin.App.resolved_providers(app, [provider]) do
      :ok
    else
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

  defp access_token(tokens) when is_binary(tokens), do: tokens
  defp access_token(tokens) when is_map(tokens), do: tokens["access_token"]

  # Deliberately not `YouWeb.RequestURL`: this URI is registered with each
  # upstream provider (Google, GitHub, …) against the canonical host, so it
  # can never follow the host the login started on.
  defp redirect_uri(_conn, provider) do
    url(~p"/auth/#{provider}/callback")
  end

  defp exchange_code(config, code, conn, provider) do
    case IdentityProviders.fetch_secret(config) do
      {:ok, client_secret} ->
        do_exchange_code(config, code, conn, provider, client_secret)

      # The stored ciphertext will not open under the current secret_key_base.
      # A rotated key makes every provider unusable until its secret is
      # re-entered, so say so rather than 500 on the login page.
      {:error, :undecryptable} ->
        {:error, :provider_misconfigured}
    end
  end

  defp do_exchange_code(config, code, conn, provider, client_secret) do
    body = %{
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri(conn, provider),
      client_id: config.client_id,
      client_secret: client_secret
    }

    # GitHub returns a form-encoded body unless asked for JSON; every OIDC
    # provider ignores the header, so it is unconditional.
    headers = [{"accept", "application/json"}]

    case Req.post(config.token_url, form: body, headers: headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "token endpoint returned #{status}"}

      {:error, %{reason: reason}} ->
        {:error, reason}
    end
  end

  # GitHub is not OIDC: it has no userinfo endpoint and no `sub` claim, so a
  # github-kind provider goes through its own adapter rather than the generic
  # OIDC fetch.
  defp fetch_userinfo(%{kind: "github"}, tokens) do
    tokens |> access_token() |> You.IdentityProviders.Github.fetch_identity()
  end

  defp fetch_userinfo(%{kind: "discord"}, tokens) do
    tokens |> access_token() |> You.IdentityProviders.Discord.fetch_identity()
  end

  defp fetch_userinfo(config, tokens) do
    headers = [{"authorization", "Bearer #{access_token(tokens)}"}]

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
