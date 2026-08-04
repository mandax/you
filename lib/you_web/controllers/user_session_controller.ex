defmodule YouWeb.UserSessionController do
  use YouWeb, :controller

  import YouWeb.AuthMethods, only: [app_for: 1, enabled_methods: 1, enabled?: 2]

  alias You.Accounts
  alias YouWeb.UserAuth

  def new(conn, params) do
    conn =
      if callback_url = params["callback_url"] do
        put_session(conn, :callback_url, callback_url)
      else
        put_session(conn, :callback_url, nil)
      end

    conn =
      if params["scope"] do
        scopes = String.split(params["scope"], " ")
        put_session(conn, :scopes, scopes)
      else
        put_session(conn, :scopes, nil)
      end

    # OAuth CSRF: the consumer's opaque `state` is stashed and echoed back on the
    # callback redirect, so the consumer can prove the response matches its request.
    conn = put_session(conn, :state, params["state"])

    # PKCE: stash the consumer's code_challenge (S256) so it can be bound to the
    # auth code minted after login and verified at exchange time.
    conn = put_session(conn, :code_challenge, params["code_challenge"])

    conn = put_session(conn, :branding_app_slug, params["app"])

    if conn.assigns[:current_scope] && conn.assigns.current_scope.user &&
         get_session(conn, :callback_url) do
      user = conn.assigns.current_scope.user
      app = app_for(conn)

      case app && app.first_party && YouWeb.OAuthFlow.authorize_signed_in(conn, user) do
        %Plug.Conn{} = conn ->
          conn

        _ ->
          app_name = if app, do: app.name, else: get_session(conn, :callback_url)

          render(
            conn,
            :authorize,
            [
              app_name: app_name,
              user_email: user.email,
              scopes: get_session(conn, :scopes) || ["email"],
              tos_url: app && app.tos_url,
              privacy_url: app && app.privacy_url
            ] ++ Keyword.drop(YouWeb.AppBranding.assigns(conn), [:app_name])
          )
      end
    else
      email = get_in(conn.assigns, [:current_scope, Access.key(:user), Access.key(:email)])
      form = Phoenix.Component.to_form(%{"email" => email}, as: "user")

      render_login(conn, form)
    end
  end

  @doc """
  Renders the login page.

  An app's login page is rendered bare — no site chrome, no brand panel, just
  the form — because it belongs to that app, not to You. Every path that
  re-renders the page after an error goes through here, or a failed login on a
  branded page would come back as You's own.
  """
  def render_login(conn, form) do
    app = app_for(conn)

    conn
    |> assign(:forced_theme, forced_theme(app))
    |> render(
      :new,
      [
        form: form,
        callback_url: get_session(conn, :callback_url),
        providers: oidc_providers(app),
        methods: enabled_methods(app)
      ] ++ YouWeb.AppBranding.assigns(conn)
    )
  end

  # Enabled upstream OIDC providers, as a sorted list of slugs ("google", …),
  # filtered to the ones the in-flight `app` allows. Hiding the button here is
  # a UX nicety only — `FederatedAuthController` is what actually gates access.
  defp oidc_providers(app) do
    You.IdentityProviders.list_enabled_providers()
    |> Enum.map(& &1.slug)
    |> then(&You.Admin.App.resolved_providers(app, &1))
    |> Enum.sort()
  end

  # "system" leaves the visitor's own preference alone; only an explicit
  # light/dark is pinned onto the document root.
  defp forced_theme(%{theme_mode: mode}) when mode in ["light", "dark"], do: mode
  defp forced_theme(_), do: nil

  # A magic link sent during an app's login flow should arrive under that
  # app's name, not You's — the user asked to sign in to the app.
  defp app_from_name(conn) do
    case app_for(conn) do
      %{email_from_name: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp reject_disabled_method(conn) do
    conn
    |> put_flash(:error, "That sign-in method is not available for this application.")
    |> redirect(to: ~p"/users/log-in?#{oauth_link_params(conn)}")
  end

  # The OAuth params stashed in the session, as a query map for embedding in
  # the magic-link URL. Omits blanks; none are secrets. The code_verifier
  # never leaves the consumer.
  defp oauth_link_params(conn) do
    scope =
      case get_session(conn, :scopes) do
        list when is_list(list) -> Enum.join(list, " ")
        _ -> nil
      end

    %{
      "callback_url" => get_session(conn, :callback_url),
      "state" => get_session(conn, :state),
      "code_challenge" => get_session(conn, :code_challenge),
      "scope" => scope
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  # magic link login
  def create(conn, %{"user" => %{"token" => token} = user_params} = params) do
    info =
      case params do
        %{"_action" => "confirmed"} -> "User confirmed successfully."
        _ -> "Welcome back!"
      end

    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, _expired_tokens}} ->
        if callback_url = safe_callback_url(conn) do
          record_consent_for_app(conn, user)
          scopes = get_session(conn, :scopes) || ["email"]
          state = get_session(conn, :state)

          {:ok, code} =
            Accounts.generate_auth_code(
              user,
              scopes,
              get_session(conn, :code_challenge),
              YouWeb.OAuthFlow.app_slug_for_callback(conn)
            )

          conn
          |> put_flash(:info, info)
          |> UserAuth.create_user_session(user, user_params)
          |> redirect_with_code(callback_url, code, state)
        else
          conn
          |> put_flash(:info, info)
          |> UserAuth.log_in_user(user, user_params)
        end

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> render_login(Phoenix.Component.to_form(%{}, as: "user"))
    end
  end

  # email + password login
  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}) do
    if not enabled?(conn, "password") do
      reject_disabled_method(conn)
    else
      do_password_login(conn, email, password, user_params)
    end
  end

  # magic link request
  def create(conn, %{"user" => %{"email" => email}}) do
    if not enabled?(conn, "magic_link") do
      reject_disabled_method(conn)
    else
      do_magic_link_request(conn, email)
    end
  end

  defp do_password_login(conn, email, password, user_params) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
        user_id: user.id,
        email: user.email,
        method: "password",
        result: :success
      })

      cond do
        user.totp_enabled ->
          conn
          |> put_session(:totp_user_id, user.id)
          |> redirect(to: ~p"/users/log-in/totp")

        user.email_2fa_enabled ->
          Accounts.send_email_2fa_code(user)

          conn
          |> put_session(:email_2fa_user_id, user.id)
          |> redirect(to: ~p"/users/log-in/email-2fa")

        true ->
          conn
          |> put_flash(:info, "Welcome back!")
          |> YouWeb.OAuthFlow.complete_login(user, user_params)
      end
    else
      :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
        email: email,
        method: "password",
        result: :failure
      })

      form = Phoenix.Component.to_form(user_params, as: "user")

      # In order to prevent user enumeration attacks, don't disclose whether the email is disclosed.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> render_login(form)
    end
  end

  defp do_magic_link_request(conn, email) do
    if user = Accounts.get_user_by_email(email) do
      # Carry the OAuth params in the magic-link URL, not just the session:
      # the link is usually opened in a different context (email client, other
      # device) where the session that stashed callback_url/state/PKCE is gone.
      link_params = oauth_link_params(conn)

      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}?#{link_params}"),
        app_from_name(conn)
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    conn
    |> put_flash(:info, info)
    |> redirect(to: ~p"/users/log-in")
  end

  def confirm(conn, params) do
    token = params["token"]

    conn =
      if callback_url = params["callback_url"] do
        put_session(conn, :callback_url, callback_url)
      else
        put_session(conn, :callback_url, nil)
      end

    conn =
      if params["scope"] do
        scopes = String.split(params["scope"], " ")
        put_session(conn, :scopes, scopes)
      else
        put_session(conn, :scopes, nil)
      end

    conn = put_session(conn, :state, params["state"])
    conn = put_session(conn, :code_challenge, params["code_challenge"])

    user = token && Accounts.get_user_by_magic_link_token(token)

    if user do
      form = Phoenix.Component.to_form(%{"token" => token}, as: "user")

      conn
      |> assign(:user, user)
      |> assign(:form, form)
      |> render(:confirm, YouWeb.AppBranding.assigns(conn))
    else
      conn
      |> put_flash(:error, "Magic link is invalid or it has expired.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def totp(conn, _params) do
    user_id = get_session(conn, :totp_user_id)

    if user_id do
      render(
        conn,
        :totp,
        [form: Phoenix.Component.to_form(%{}, as: "totp")] ++ YouWeb.AppBranding.assigns(conn)
      )
    else
      conn
      |> put_flash(:error, "Session expired, please log in again.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def verify_totp(conn, %{"totp" => %{"code" => code}}) do
    user_id = get_session(conn, :totp_user_id)

    if user_id do
      user = Accounts.get_user!(user_id)

      if Accounts.verify_totp(user, code) do
        audit_totp(user, :success)

        conn
        |> put_session(:totp_user_id, nil)
        |> put_flash(:info, "Welcome back!")
        |> YouWeb.OAuthFlow.complete_login(user)
      else
        audit_totp(user, :failure)

        render(
          conn,
          :totp,
          [
            form: Phoenix.Component.to_form(%{}, as: "totp"),
            error: "Invalid code. Please try again."
          ] ++ YouWeb.AppBranding.assigns(conn)
        )
      end
    else
      conn
      |> put_flash(:error, "Session expired, please log in again.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Renders the recovery-code form for a user mid-TOTP login who has lost
  access to their authenticator app.
  """
  def recovery_code(conn, _params) do
    user_id = get_session(conn, :totp_user_id)

    if user_id do
      render(
        conn,
        :recovery_code,
        [form: Phoenix.Component.to_form(%{}, as: "recovery")] ++
          YouWeb.AppBranding.assigns(conn)
      )
    else
      conn
      |> put_flash(:error, "Session expired, please log in again.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def verify_recovery_code(conn, %{"recovery" => %{"code" => code}}) do
    user_id = get_session(conn, :totp_user_id)

    if user_id do
      user = Accounts.get_user!(user_id)

      case Accounts.verify_recovery_code(user, code) do
        {:ok, user} ->
          :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
            user_id: user.id,
            email: user.email,
            method: "recovery_code",
            result: :success
          })

          conn
          |> put_session(:totp_user_id, nil)
          |> put_flash(:info, "Welcome back!")
          |> YouWeb.OAuthFlow.complete_login(user)

        {:error, :invalid_code} ->
          :telemetry.execute([:you, :audit, :login, :attempt], %{}, %{
            user_id: user.id,
            email: user.email,
            method: "recovery_code",
            result: :failure
          })

          render(
            conn,
            :recovery_code,
            [
              form: Phoenix.Component.to_form(%{}, as: "recovery"),
              error: "Invalid or already-used recovery code."
            ] ++ YouWeb.AppBranding.assigns(conn)
          )
      end
    else
      conn
      |> put_flash(:error, "Session expired, please log in again.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def authorize_action(conn, _params) do
    user = conn.assigns.current_scope.user

    case user && YouWeb.OAuthFlow.authorize_signed_in(conn, user) do
      %Plug.Conn{} = conn ->
        conn

      _ ->
        conn
        |> put_flash(:error, "Session expired, please log in again.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # ── Email 2FA (second factor: a code emailed after password login) ──

  def email_2fa(conn, _params) do
    if get_session(conn, :email_2fa_user_id) do
      render(
        conn,
        :email_2fa,
        [form: Phoenix.Component.to_form(%{}, as: "email_2fa")] ++
          YouWeb.AppBranding.assigns(conn)
      )
    else
      conn
      |> put_flash(:error, "Session expired, please log in again.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def verify_email_2fa(conn, %{"email_2fa" => %{"code" => code}}) do
    user_id = get_session(conn, :email_2fa_user_id)

    if user_id do
      user = Accounts.get_user!(user_id)

      case Accounts.verify_email_2fa_code(user, code) do
        :ok ->
          conn
          |> put_session(:email_2fa_user_id, nil)
          |> put_flash(:info, "Welcome back!")
          |> YouWeb.OAuthFlow.complete_login(user)

        {:error, :invalid_code} ->
          render(
            conn,
            :email_2fa,
            [
              form: Phoenix.Component.to_form(%{}, as: "email_2fa"),
              error: "Invalid or expired code. Please try again."
            ] ++ YouWeb.AppBranding.assigns(conn)
          )
      end
    else
      conn
      |> put_flash(:error, "Session expired, please log in again.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def resend_email_2fa(conn, _params) do
    case get_session(conn, :email_2fa_user_id) do
      nil ->
        redirect(conn, to: ~p"/users/log-in")

      user_id ->
        user_id |> Accounts.get_user!() |> Accounts.send_email_2fa_code()

        conn
        |> put_flash(:info, "A new code has been sent to your email.")
        |> redirect(to: ~p"/users/log-in/email-2fa")
    end
  end

  # The second factor gets its own audit event so a login and the TOTP step
  # that gated it stay distinguishable in the log.
  defp audit_totp(user, result) do
    :telemetry.execute([:you, :audit, :login, :totp], %{}, %{
      user_id: user.id,
      email: user.email,
      method: "totp",
      result: result
    })
  end

  # OAuth-completion helpers shared with the federated/social login path.
  defdelegate redirect_with_code(conn, callback_url, code, state), to: YouWeb.OAuthFlow
  defdelegate safe_callback_url(conn), to: YouWeb.OAuthFlow
  defdelegate record_consent_for_app(conn, user), to: YouWeb.OAuthFlow

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
