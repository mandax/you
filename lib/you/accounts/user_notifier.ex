defmodule You.Accounts.UserNotifier do
  import Swoosh.Email

  alias You.Mailer
  alias You.Accounts.User

  @default_from_name "You"

  defp deliver(recipient, subject, body, from_name \\ nil) do
    email =
      new()
      |> to(recipient)
      |> from({from_name || @default_from_name, Mailer.from_address()})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url, from_name \\ nil) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url, from_name)
      _ -> deliver_magic_link_instructions(user, url, from_name)
    end
  end

  @doc """
  Deliver a one-time email 2FA code.
  """
  def deliver_email_2fa_code(user, code, from_name \\ nil) do
    deliver(
      user.email,
      "Your verification code",
      """

      ==============================

      Hi #{user.email},

      Your verification code is:

      #{code}

      It expires in 10 minutes. If you didn't try to sign in, ignore this email
      and consider changing your password.

      ==============================
      """,
      from_name
    )
  end

  defp deliver_magic_link_instructions(user, url, from_name) do
    deliver(
      user.email,
      "Log in instructions",
      """

      ==============================

      Hi #{user.email},

      You can log into your account by visiting the URL below:

      #{url}

      If you didn't request this email, please ignore this.

      ==============================
      """,
      from_name
    )
  end

  defp deliver_confirmation_instructions(user, url, from_name) do
    deliver(
      user.email,
      "Confirmation instructions",
      """

      ==============================

      Hi #{user.email},

      You can confirm your account by visiting the URL below:

      #{url}

      If you didn't create an account with us, please ignore this.

      ==============================
      """,
      from_name
    )
  end

  @doc """
  Deliver instructions to reset a password.
  """
  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Reset password instructions", """

    ==============================

    Hi #{user.email},

    You can reset your password by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end
end
