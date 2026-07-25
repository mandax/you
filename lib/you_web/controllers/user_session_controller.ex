defmodule YouWeb.UserSessionController do
  use YouWeb, :controller

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

    if conn.assigns[:current_scope] && conn.assigns.current_scope.user &&
         get_session(conn, :callback_url) do
      app_name =
        case You.Admin.lookup_app_by_callback(get_session(conn, :callback_url)) do
          {:ok, app} -> app.name
          :error -> get_session(conn, :callback_url)
        end

      render(conn, :authorize,
        app_name: app_name,
        user_email: conn.assigns.current_scope.user.email,
        scopes: get_session(conn, :scopes) || ["email"]
      )
    else
      email = get_in(conn.assigns, [:current_scope, Access.key(:user), Access.key(:email)])
      form = Phoenix.Component.to_form(%{"email" => email}, as: "user")
      app = app_for(conn)

      render(conn, :new,
        form: form,
        callback_url: get_session(conn, :callback_url),
        providers: oidc_providers(),
        app_name: app && app.name,
        app_logo_url: app && app.logo_url,
        app_brand_color: app && app.brand_color
      )
    end
  end

  # Registered app in an OAuth login flow ("sign in to continue to <app>");
  # nil for a plain login. Its branding (logo_url, brand_color) optionally
  # customizes the login page.
  defp app_for(conn) do
    with url when is_binary(url) <- get_session(conn, :callback_url),
         {:ok, app} <- You.Admin.lookup_app_by_callback(url) do
      app
    else
      _ -> nil
    end
  end

  # Configured upstream OIDC providers, as a sorted list of ids ("google", …).
  defp oidc_providers do
    Application.get_env(:you, :oidc_providers, %{}) |> Map.keys() |> Enum.sort()
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
        |> render(:new,
          form: Phoenix.Component.to_form(%{}, as: "user"),
          callback_url: get_session(conn, :callback_url),
          providers: oidc_providers()
        )
    end
  end

  # email + password login
  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}) do
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
      |> render(:new,
        form: form,
        callback_url: get_session(conn, :callback_url),
        providers: oidc_providers()
      )
    end
  end

  # magic link request
  def create(conn, %{"user" => %{"email" => email}}) do
    if user = Accounts.get_user_by_email(email) do
      # Carry the OAuth params in the magic-link URL, not just the session:
      # the link is usually opened in a different context (email client, other
      # device) where the session that stashed callback_url/state/PKCE is gone.
      link_params = oauth_link_params(conn)

      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}?#{link_params}")
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
      |> render(:confirm)
    else
      conn
      |> put_flash(:error, "Magic link is invalid or it has expired.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def totp(conn, _params) do
    user_id = get_session(conn, :totp_user_id)

    if user_id do
      render(conn, :totp, form: Phoenix.Component.to_form(%{}, as: "totp"))
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
        callback_url = safe_callback_url(conn)

        if callback_url do
          record_consent_for_app(conn, user)
          scopes = get_session(conn, :scopes) || ["email"]
          state = get_session(conn, :state)

          {:ok, auth_code} =
            Accounts.generate_auth_code(
              user,
              scopes,
              get_session(conn, :code_challenge),
              YouWeb.OAuthFlow.app_slug_for_callback(conn)
            )

          conn
          |> UserAuth.create_user_session(user, %{})
          |> put_session(:totp_user_id, nil)
          |> redirect_with_code(callback_url, auth_code, state)
        else
          conn
          |> put_flash(:info, "Welcome back!")
          |> UserAuth.log_in_user(user, %{})
        end
      else
        render(conn, :totp,
          form: Phoenix.Component.to_form(%{}, as: "totp"),
          error: "Invalid code. Please try again."
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
    callback_url = safe_callback_url(conn)

    if user && callback_url do
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

      redirect_with_code(conn, callback_url, code, state)
    else
      conn
      |> put_flash(:error, "Session expired, please log in again.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  # ── Email 2FA (second factor: a code emailed after password login) ──

  def email_2fa(conn, _params) do
    if get_session(conn, :email_2fa_user_id) do
      render(conn, :email_2fa, form: Phoenix.Component.to_form(%{}, as: "email_2fa"))
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
          render(conn, :email_2fa,
            form: Phoenix.Component.to_form(%{}, as: "email_2fa"),
            error: "Invalid or expired code. Please try again."
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
