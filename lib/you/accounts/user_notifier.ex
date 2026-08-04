defmodule You.Accounts.UserNotifier do
  @moduledoc """
  Sends You's transactional mail.

  The copy lives in `You.EmailTemplates`, which an admin can override per
  template; this module decides which template a given event uses and what
  it substitutes into it.
  """
  import Swoosh.Email

  alias You.Accounts.User
  alias You.EmailTemplates
  alias You.Mailer

  @default_from_name "You"

  defp deliver(recipient, template, assigns, from_name \\ nil) do
    {subject, body} = EmailTemplates.render(template, assigns)

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
    deliver(user.email, "update_email", %{email: user.email, url: url})
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url, from_name \\ nil) do
    template = if match?(%User{confirmed_at: nil}, user), do: "confirmation", else: "magic_link"

    deliver(
      user.email,
      template,
      %{email: user.email, url: url, app_name: from_name || @default_from_name},
      from_name
    )
  end

  @doc """
  Deliver a one-time email 2FA code.
  """
  def deliver_email_2fa_code(user, code, from_name \\ nil) do
    deliver(
      user.email,
      "email_2fa",
      %{email: user.email, code: code, app_name: from_name || @default_from_name},
      from_name
    )
  end

  @doc """
  Deliver an admin's invitation to join an app.

  Addressed to an email rather than a user: the invitee may have no account
  here yet, which is the case the invitation exists for.
  """
  def deliver_invitation(email, assigns) do
    deliver(email, "invitation", Map.put(assigns, :email, email), assigns[:app_name])
  end

  @doc """
  Deliver instructions to reset a password.
  """
  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "reset_password", %{email: user.email, url: url})
  end
end
