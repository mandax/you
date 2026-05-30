defmodule YouWeb.UserRegistrationController do
  use YouWeb, :controller

  alias You.Accounts
  alias You.Accounts.User

  def new(conn, params) do
    conn =
      if callback_url = params["callback_url"] do
        conn |> put_session(:callback_url, callback_url)
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

    changeset = Accounts.change_user_email(%User{})
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"user" => user_params}) do
    callback_url = get_session(conn, :callback_url)
    scopes = get_session(conn, :scopes)

    case Accounts.register_user(user_params) do
      {:ok, user} ->
        url_fun =
          if callback_url do
            fn token ->
              base = url(~p"/users/log-in/#{token}")
              extra = ["callback_url=#{URI.encode(callback_url)}"]
              extra = if scopes, do: ["scope=#{Enum.join(scopes, "+")}" | extra], else: extra
              base <> "?" <> Enum.join(extra, "&")
            end
          else
            &url(~p"/users/log-in/#{&1}")
          end

        {:ok, _} = Accounts.deliver_login_instructions(user, url_fun)

        conn
        |> put_flash(
          :info,
          "An email was sent to #{user.email}, please access it to confirm your account."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)
    end
  end
end
