defmodule YouWeb.UserResetPasswordController do
  use YouWeb, :controller

  alias You.Accounts

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

    render(conn, :new)
  end

  def create(conn, %{"user" => %{"email" => email}}) do
    if user = Accounts.get_user_by_email(email) do
      callback_url = get_session(conn, :callback_url)
      scopes = get_session(conn, :scopes)

      url_fun =
        fn token ->
          base = url(~p"/users/reset-password/#{token}")
          extra = []

          extra =
            if callback_url, do: ["callback_url=#{URI.encode(callback_url)}" | extra], else: extra

          extra = if scopes, do: ["scope=#{Enum.join(scopes, "+")}" | extra], else: extra

          if extra == [] do
            base
          else
            base <> "?" <> Enum.join(extra, "&")
          end
        end

      Accounts.deliver_user_reset_password_instructions(user, url_fun)
    end

    conn
    |> put_flash(
      :info,
      "If your email is in our system, you will receive instructions to reset your password shortly."
    )
    |> redirect(to: ~p"/users/log-in")
  end

  def edit(conn, %{"token" => token} = params) do
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

    if user = Accounts.get_user_by_reset_password_token(token) do
      changeset = Accounts.change_user_password(user)
      render(conn, :edit, changeset: changeset, token: token)
    else
      conn
      |> put_flash(:error, "Reset password link is invalid or it has expired.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def update(conn, %{"user" => user_params, "token" => token}) do
    if user = Accounts.get_user_by_reset_password_token(token) do
      case Accounts.update_user_password(user, user_params) do
        {:ok, user} ->
          Accounts.delete_all_user_tokens(user)

          callback_url = get_session(conn, :callback_url)
          scopes = get_session(conn, :scopes)

          if callback_url do
            {:ok, code} = Accounts.generate_auth_code(user, scopes)

            conn
            |> put_flash(:info, "Password reset successfully.")
            |> put_session(:callback_url, nil)
            |> put_session(:scopes, nil)
            |> redirect(external: "#{callback_url}?code=#{code}")
          else
            conn
            |> put_flash(:info, "Password reset successfully.")
            |> redirect(to: ~p"/users/log-in")
          end

        {:error, changeset} ->
          render(conn, :edit, changeset: changeset, token: token)
      end
    else
      conn
      |> put_flash(:error, "Reset password link is invalid or it has expired.")
      |> redirect(to: ~p"/users/log-in")
    end
  end
end
