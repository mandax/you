defmodule You.EmailTemplates do
  @moduledoc """
  The transactional emails You sends, and the admin's overrides for them.

  `UserNotifier`'s copy used to be compiled in, so every instance's magic
  link, confirmation, reset and 2FA emails went out in You's default wording —
  which reads as You's product voice, not the operator's, on an email their
  users receive.

  ## Overrides, not copies

  Only customised templates get a row. A template nobody has touched keeps
  using the copy here, so an instance that never opens this screen still picks
  up improvements to the default wording, and "reset to default" is a delete
  rather than restoring a snapshot of whatever the default was on the day the
  screen was first saved.

  ## Substitution

  Bodies interpolate `{{name}}` placeholders from a fixed set per template —
  plain string replacement, never evaluation. An unknown placeholder is left
  as written rather than blanked: an admin who typos `{{ur}}` should see it in
  the test email, not send a login with a hole where the link was.

  The placeholders a template cannot do without (`url` in a magic link, `code`
  in a 2FA email) are required by the changeset.
  """

  import Ecto.Query, warn: false

  alias You.EmailTemplates.EmailTemplate
  alias You.Repo

  @templates [
    %{
      key: "magic_link",
      label: "Magic link",
      description: "Sent when a returning user asks to sign in by email.",
      variables: ~w(email url app_name),
      required: ~w(url),
      subject: "Log in instructions",
      body: """

      ==============================

      Hi {{email}},

      You can log into your account by visiting the URL below:

      {{url}}

      If you didn't request this email, please ignore this.

      ==============================
      """
    },
    %{
      key: "confirmation",
      label: "Confirmation",
      description: "Sent instead of the magic link when the account is not confirmed yet.",
      variables: ~w(email url app_name),
      required: ~w(url),
      subject: "Confirmation instructions",
      body: """

      ==============================

      Hi {{email}},

      You can confirm your account by visiting the URL below:

      {{url}}

      If you didn't create an account with us, please ignore this.

      ==============================
      """
    },
    %{
      key: "reset_password",
      label: "Password reset",
      description: "Sent when a user asks to reset their password.",
      variables: ~w(email url),
      required: ~w(url),
      subject: "Reset password instructions",
      body: """

      ==============================

      Hi {{email}},

      You can reset your password by visiting the URL below:

      {{url}}

      If you didn't request this change, please ignore this.

      ==============================
      """
    },
    %{
      key: "update_email",
      label: "Email change",
      description: "Sent to the new address when a user changes the email on their account.",
      variables: ~w(email url),
      required: ~w(url),
      subject: "Update email instructions",
      body: """

      ==============================

      Hi {{email}},

      You can change your email by visiting the URL below:

      {{url}}

      If you didn't request this change, please ignore this.

      ==============================
      """
    },
    %{
      key: "email_2fa",
      label: "Two-factor code",
      description: "The one-time code sent as a second factor after a password login.",
      variables: ~w(email code app_name),
      required: ~w(code),
      subject: "Your verification code",
      body: """

      ==============================

      Hi {{email}},

      Your verification code is:

      {{code}}

      It expires in 10 minutes. If you didn't try to sign in, ignore this email
      and consider changing your password.

      ==============================
      """
    }
  ]

  @keys Enum.map(@templates, & &1.key)

  @doc "Every template You sends, in the order the console lists them."
  def definitions, do: @templates

  @doc "The template keys, for validating an incoming key."
  def keys, do: @keys

  @doc "The definition for `key`, or nil."
  def definition(key), do: Enum.find(@templates, &(&1.key == key))

  @doc """
  The subject and body for `key` with `assigns` substituted, as
  `{subject, body}`.

  Falls back to the compiled-in default when no override exists, and when the
  stored override is for a key this version no longer knows.
  """
  def render(key, assigns \\ %{}) do
    case definition(key) do
      nil -> raise ArgumentError, "unknown email template: #{inspect(key)}"
      definition -> render_definition(definition, assigns)
    end
  end

  defp render_definition(definition, assigns) do
    override = get_override(definition.key)
    subject = (override && override.subject) || definition.subject
    body = (override && override.body) || definition.body

    {substitute(subject, assigns), substitute(body, assigns)}
  end

  @doc """
  The stored override for `key`, or nil when the template is at its default.
  """
  def get_override(key) when is_binary(key), do: Repo.get_by(EmailTemplate, key: key)

  @doc "Every stored override, keyed by template key."
  def overrides, do: Map.new(Repo.all(EmailTemplate), &{&1.key, &1})

  @doc """
  Stores an override for `key`. Returns `{:ok, template}` or
  `{:error, changeset}`, and `{:error, :unknown_template}` for a key You does
  not send.
  """
  def upsert(key, attrs) when is_binary(key) do
    case definition(key) do
      nil -> {:error, :unknown_template}
      definition -> do_upsert(definition, attrs)
    end
  end

  defp do_upsert(definition, attrs) do
    existing = get_override(definition.key) || %EmailTemplate{}
    attrs = attrs |> Map.new() |> Map.put("key", definition.key)

    existing
    |> EmailTemplate.changeset(attrs, definition.required)
    |> Repo.insert_or_update()
  end

  @doc """
  Drops the override for `key`, putting the template back to its default.
  Succeeds whether or not one existed.
  """
  def reset(key) when is_binary(key) do
    Repo.delete_all(from t in EmailTemplate, where: t.key == ^key)
    :ok
  end

  # String replacement over a fixed set of names. Anything not in `assigns` is
  # left as written, so a typo shows up in the sent mail rather than silently
  # becoming an empty space where a login link should be.
  defp substitute(text, assigns) do
    Enum.reduce(assigns, text, fn {name, value}, acc ->
      String.replace(acc, "{{#{name}}}", to_string(value))
    end)
  end
end
