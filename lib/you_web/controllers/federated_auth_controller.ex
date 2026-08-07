defmodule YouWeb.FederatedAuthController do
  use YouWeb, :controller

  alias YouWeb.AuthMethods
  alias You.{Accounts, Admin, IdentityProviders}

  @nonce_cookie "_you_login_flow_nonce"

  @doc """
  GET /auth/:provider

  Starts a federated login flow and redirects to the upstream IdP.

  `ctx` (`callback_url`, `scopes`, `code_challenge`, `branding_app_slug`, and
  the consumer app's own `state`) travels to the callback through a
  server-side flow record rather than the session, keyed by an opaque
  `state` sent as the OIDC `state` param — see
  `You.IdentityProviders.LoginFlow`. A binding nonce cookie is set on this
  response and must be presented again at the callback: that comparison,
  not the `state` value itself, is the CSRF defence.

  Reads `ctx` from the request when present (the carrier #121's app-host
  social button will use to reach this canonical route), falling back to
  today's session-carried values when it is not — which is always, until
  #121 links to here from another host.

  `ctx` is resolved *before* the per-app provider gate: the gate has to name
  the app `ctx` names, not whatever the session (if any) on this host
  happens to hold — otherwise a cross-host `ctx` naming an app that
  disallows this provider would find no app in the session and fall through
  to "unrestricted" (#132 review).
  """
  def authorize(conn, %{"provider" => provider} = params) do
    with {:ok, config} <- fetch_provider_config(provider),
         {:ok, ctx} <- resolve_ctx(conn, params),
         :ok <- authorize_for_app(ctx, provider) do
      {state, nonce} = IdentityProviders.start_login_flow(provider, ctx)

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
      |> put_login_flow_nonce_cookie(nonce)
      |> redirect(external: authorize_url)
    else
      {:error, :invalid_ctx} ->
        conn
        |> put_flash(:error, "Your sign-in attempt expired. Please try again.")
        |> redirect(to: ~p"/users/log-in")

      :error ->
        conn
        |> put_flash(:error, "Unknown authentication provider.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  GET /auth/:provider/callback

  Handles the OIDC callback: verifies `state` against its flow record and the
  binding nonce cookie against that record's stored hash, re-checks the
  per-app provider gate against the flow's own `ctx` (config can have changed
  mid-flight, and on a cross-host arrival there is no session to check
  instead — #132 review), exchanges the authorization code for tokens,
  fetches the userinfo, and logs the user in.
  """
  def callback(conn, %{"provider" => provider, "code" => code, "state" => state}) do
    with {:ok, config} <- fetch_provider_config(provider),
         {:ok, ctx} <- verify_state(conn, provider, state),
         :ok <- authorize_for_app(ctx, provider),
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
        request_host_claimed: conn.host
      })

      # An identity provider proves the first factor only: an account with a
      # second factor enrolled still has to meet it. Past that, the login goes
      # back to the requesting app as an authorization code when this started
      # from an OAuth flow, and is otherwise a plain sign-in to You.
      conn
      |> clear_login_flow_nonce_cookie()
      |> restore_flow_session(ctx)
      |> YouWeb.SecondFactor.complete_login(user, "Welcome back!")
    else
      {:error, :state_mismatch} ->
        :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
          method: "oidc:#{provider}",
          result: :failure,
          reason: :state_mismatch,
          request_host_claimed: conn.host
        })

        conn
        |> clear_login_flow_nonce_cookie()
        |> put_flash(:error, "Authentication failed: state mismatch.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :transaction_aborted} ->
        conn
        |> clear_login_flow_nonce_cookie()
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :provider_misconfigured} ->
        conn
        |> clear_login_flow_nonce_cookie()
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
          request_host_claimed: conn.host
        })

        conn
        |> clear_login_flow_nonce_cookie()
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
          request_host_claimed: conn.host
        })

        conn
        |> clear_login_flow_nonce_cookie()
        |> put_flash(:error, "Authentication failed: #{reason}")
        |> redirect(to: ~p"/users/log-in")

      :error ->
        conn
        |> clear_login_flow_nonce_cookie()
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
  #
  # Takes `ctx` rather than `conn`: the app this gate has to check against is
  # the one `ctx` names (`callback_url`/`branding_app_slug`), not whatever
  # the session on the host handling this request happens to hold. Today
  # those are the same thing (`ctx` falls back to session — see
  # `resolve_ctx/2`); once #121 lands they will not be, and the session on
  # canonical is simply absent.
  defp authorize_for_app(ctx, provider) do
    app = AuthMethods.app_for(ctx["callback_url"], ctx["branding_app_slug"])

    if AuthMethods.enabled?(app, "social") and
         provider in Admin.App.resolved_providers(app, [provider]) do
      :ok
    else
      :error
    end
  end

  # `ctx` present and valid: this is (the future) cross-host arrival from an
  # app host, per #121. Otherwise, fall back to the session values this
  # request already carries — today's only path, since nothing mints a
  # signed `ctx` yet.
  defp resolve_ctx(_conn, %{"ctx" => signed}) when is_binary(signed) do
    case IdentityProviders.verify_ctx(signed) do
      {:ok, ctx} -> {:ok, ctx}
      :error -> {:error, :invalid_ctx}
    end
  end

  defp resolve_ctx(conn, _params), do: {:ok, session_ctx(conn)}

  # `state` here is the *consumer app's* OAuth CSRF token (`user_session_
  # controller.ex` stashes it from `?state=` at the start of the app's own
  # OAuth handoff to You) — unrelated to the OIDC `state` this controller
  # sends the IdP, confusing as the shared name is. It has to travel in `ctx`
  # too: `OAuthFlow.redirect_with_code/4` echoes it back to the consumer app
  # so the app can check its own request matches its own response, and it
  # silently omits it rather than failing when absent. Drop it here and a
  # cross-host social login hands the app a code with no `state` — the same
  # class of gap this issue closes, one layer out.
  defp session_ctx(conn) do
    %{
      "callback_url" => get_session(conn, :callback_url),
      "scopes" => get_session(conn, :scopes),
      "code_challenge" => get_session(conn, :code_challenge),
      "branding_app_slug" => get_session(conn, :branding_app_slug),
      "state" => get_session(conn, :state)
    }
  end

  # The values `authorize/2` captured into the flow record's `ctx`, restored
  # into the session so `YouWeb.OAuthFlow.complete_login/3` finds them exactly
  # as it does for every other login method. On canonical today this is a
  # round trip to the same values already in the session; once #121 lands, an
  # app-host `ctx` arrives here for the first time.
  defp restore_flow_session(conn, ctx) do
    conn
    |> put_session(:callback_url, ctx["callback_url"])
    |> put_session(:scopes, ctx["scopes"])
    |> put_session(:code_challenge, ctx["code_challenge"])
    |> put_session(:branding_app_slug, ctx["branding_app_slug"])
    |> put_session(:state, ctx["state"])
  end

  defp verify_state(conn, provider, state) do
    conn = fetch_cookies(conn)
    IdentityProviders.consume_login_flow(provider, state, conn.cookies[@nonce_cookie])
  end

  # Its own name, HttpOnly, short-lived, and scoped to the callback path —
  # never the session cookie. `secure` follows the same runtime scheme switch
  # the session cookie does (`YouWeb.Endpoint`), so it is not sent at all
  # over plain http in dev or test.
  #
  # `SameSite=Lax`, not `Strict`: the callback arrives as a top-level
  # cross-site GET redirect *from the IdP*, not from this instance, so a
  # browser attaches a `Strict` cookie to nothing there — the check this
  # cookie exists to make would refuse every real social login. `Lax` still
  # withholds it from the cross-site POSTs and subresource requests CSRF
  # actually rides in on; only top-level GET navigation is exempt.
  defp put_login_flow_nonce_cookie(conn, nonce) do
    put_resp_cookie(conn, @nonce_cookie, nonce,
      http_only: true,
      same_site: "Lax",
      secure: secure_cookies?(),
      max_age: nonce_cookie_max_age_seconds(),
      path: "/auth"
    )
  end

  # Kept in lockstep with the flow record's own expiry (`LoginFlow.
  # validity_in_minutes/0`) rather than a second literal: a cookie that
  # outlives its flow record is inert (the record is gone, so it can never
  # match), and a cookie that expires first would refuse a legitimate,
  # still-valid flow for no reason — either mismatch is a bug waiting for
  # someone to change one without the other.
  defp nonce_cookie_max_age_seconds, do: IdentityProviders.LoginFlow.validity_in_minutes() * 60

  defp clear_login_flow_nonce_cookie(conn) do
    delete_resp_cookie(conn, @nonce_cookie, path: "/auth")
  end

  defp secure_cookies?, do: Application.get_env(:you, :secure_cookies, false)

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
