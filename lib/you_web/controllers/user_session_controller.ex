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

      render(conn, :new, form: form)
    end
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
          {:ok, code} = Accounts.generate_auth_code(user, scopes)

          conn
          |> put_flash(:info, info)
          |> UserAuth.create_user_session(user, user_params)
          |> put_session(:callback_url, nil)
          |> redirect(external: "#{callback_url}?code=#{code}")
        else
          conn
          |> put_flash(:info, info)
          |> UserAuth.log_in_user(user, user_params)
        end

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> render(:new, form: Phoenix.Component.to_form(%{}, as: "user"))
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

      if user.totp_enabled do
        conn
        |> put_session(:totp_user_id, user.id)
        |> redirect(to: ~p"/users/log-in/totp")
      else
        if callback_url = safe_callback_url(conn) do
          record_consent_for_app(conn, user)
          scopes = get_session(conn, :scopes) || ["email"]
          {:ok, code} = Accounts.generate_auth_code(user, scopes)

          conn
          |> put_flash(:info, "Welcome back!")
          |> UserAuth.create_user_session(user, user_params)
          |> put_session(:callback_url, nil)
          |> redirect(external: "#{callback_url}?code=#{code}")
        else
          conn
          |> put_flash(:info, "Welcome back!")
          |> UserAuth.log_in_user(user, user_params)
        end
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
      |> render(:new, form: form)
    end
  end

  # magic link request
  def create(conn, %{"user" => %{"email" => email}}) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
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
          {:ok, auth_code} = Accounts.generate_auth_code(user, scopes)

          conn
          |> UserAuth.create_user_session(user, %{})
          |> put_session(:totp_user_id, nil)
          |> put_session(:callback_url, nil)
          |> redirect(external: "#{callback_url}?code=#{auth_code}")
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
      {:ok, code} = Accounts.generate_auth_code(user, scopes)

      conn
      |> put_session(:callback_url, nil)
      |> put_session(:scopes, nil)
      |> redirect(external: "#{callback_url}?code=#{code}")
    else
      conn
      |> put_flash(:error, "Session expired, please log in again.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  defp safe_callback_url(conn) do
    callback_url = get_session(conn, :callback_url)

    if callback_url do
      case You.Admin.lookup_app_by_callback(callback_url) do
        {:ok, _app} -> callback_url
        :error -> nil
      end
    end
  end

  defp record_consent_for_app(conn, user) do
    callback_url = get_session(conn, :callback_url)
    scopes = get_session(conn, :scopes) || ["email"]

    if callback_url do
      case You.Admin.lookup_app_by_callback(callback_url) do
        {:ok, app} ->
          Accounts.record_consent(user, app, scopes)
          :ok

        :error ->
          :ok
      end
    else
      :ok
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
