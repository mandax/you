defmodule You.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias You.Repo

  alias You.Accounts.{User, UserToken, UserNotifier, RecoveryCode, Consent}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `You.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `You.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    expiry_hours = You.Settings.get(:session_expiry_hours)
    {:ok, query} = UserToken.verify_session_token_query(token, expiry_hours)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    expiry = You.Settings.get(:magic_link_expiry_minutes)

    with {:ok, query} <- UserToken.verify_magic_link_token_query(token, expiry),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    expiry = You.Settings.get(:magic_link_expiry_minutes)
    {:ok, query} = UserToken.verify_magic_link_token_query(token, expiry)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Auth Code

  @doc """
  Generates a single-use authorization code for the OAuth-like redirect flow.

  The code is valid for 5 minutes. Returns `{:ok, code}`.
  """
  def generate_auth_code(%User{} = user, scopes \\ nil) do
    {code, user_token} = UserToken.build_auth_token(user, scopes)
    Repo.insert!(user_token)
    {:ok, code}
  end

  @doc """
  Consumes an authorization code, returning the user if valid.

  Returns `{:ok, user}` or `{:error, :not_found}`.
  """
  def consume_auth_code(code) when is_binary(code) do
    expiry = You.Settings.get(:code_expiry_minutes)

    with {:ok, query} <- UserToken.verify_auth_code_query(code, expiry) do
      case Repo.one(query) do
        {user, token} ->
          scopes = parse_meta_scopes(token.meta)
          Repo.delete!(token)
          {:ok, user, scopes}

        nil ->
          {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp parse_meta_scopes(nil), do: ["email"]

  defp parse_meta_scopes(meta) when is_binary(meta) do
    case Jason.decode(meta) do
      {:ok, %{"scopes" => scopes}} when is_list(scopes) -> scopes
      _ -> ["email"]
    end
  end

  ## 2FA

  @doc """
  Generates a TOTP setup for a user.

  Returns `{:ok, %{secret: secret, uri: uri}}`.
  The secret is already stored on the user record (replaced on each call).
  """
  def generate_totp_setup(%User{} = user) do
    secret = NimbleTOTP.secret()
    uri = NimbleTOTP.otpauth_uri(secret, user.email, issuer: "You")

    # Store the secret on the user record so verify_totp can check codes
    {:ok, updated_user} =
      user
      |> Ecto.Changeset.change(totp_secret: secret)
      |> Repo.update()

    {:ok, %{secret: secret, uri: uri, user: updated_user}}
  end

  @doc """
  Enables TOTP for a user after verifying the current code.

  Generates 8 recovery codes (bcrypt-hashed).
  Returns `{:ok, %{user: user, recovery_codes: [string]}}` or `{:error, :invalid_code}`.
  """
  def enable_totp(%User{} = user, code) when is_binary(code) do
    enable_totp_if_valid(user, verify_totp_secret(user, code))
  end

  defp enable_totp_if_valid(user, true), do: enable_totp_with_codes(user)
  defp enable_totp_if_valid(_user, _valid), do: {:error, :invalid_code}

  defp enable_totp_with_codes(user) do
    recovery_codes = generate_recovery_codes(user)

    user
    |> Ecto.Changeset.change(totp_enabled: true)
    |> Repo.update!()

    {:ok, %{user: user, totp_enabled: true, recovery_codes: recovery_codes}}
  end

  @doc """
  Anonymizes a user's personal data for LGPD right to deletion.

  The user row stays (referential integrity) but is functionally dead.
  All sessions, tokens, and recovery codes are deleted.
  """
  def anonymize_user(%User{} = user) do
    uuid = Ecto.UUID.generate()

    result =
      Repo.transact(fn ->
        updated =
          user
          |> Ecto.Changeset.change(%{
            email: "redacted-#{uuid}@anonymized.you",
            hashed_password: nil,
            totp_secret: nil,
            totp_enabled: false,
            confirmed_at: nil
          })
          |> Repo.update!()

        Repo.delete_all(from(t in UserToken, where: t.user_id == ^user.id))
        Repo.delete_all(from(r in RecoveryCode, where: r.user_id == ^user.id))
        Repo.delete_all(from(c in Consent, where: c.user_id == ^user.id))

        {:ok, updated}
      end)

    result
  end

  @doc """
  Verifies a TOTP code against the user's stored secret.

  Returns `true` or `false`.
  """
  def verify_totp(%User{totp_secret: nil}, _code), do: false

  def verify_totp(%User{} = user, code) when is_binary(code) do
    verify_totp_secret(user, code)
  end

  defp verify_totp_secret(%User{totp_secret: nil}, _code), do: false

  defp verify_totp_secret(%User{totp_secret: secret}, code) do
    NimbleTOTP.valid?(secret, code)
  end

  defp generate_recovery_codes(%User{} = user) do
    codes = for _ <- 1..8, do: generate_code()

    Enum.each(codes, fn code ->
      Repo.insert!(%RecoveryCode{
        user_id: user.id,
        code_hash: Bcrypt.hash_pwd_salt(code),
        used: false
      })
    end)

    codes
  end

  defp generate_code do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  ## LGPD: JTI cleanup

  @doc """
  Deletes expired JTI revocation entries. Runs periodically.
  Retention is `jwt_expiry_hours + 1 hour` grace period.
  """
  def cleanup_revoked_jtis do
    retention_hours = You.Settings.get(:jwt_expiry_hours) + 1
    threshold = DateTime.add(DateTime.utc_now(), -retention_hours * 3600, :second)

    Repo.delete_all(
      from t in UserToken,
        where: t.context == "jti_revoked" and t.inserted_at < ^threshold
    )
  end

  ## LGPD: Consent

  @doc """
  Records a consent grant for a user-app pair.
  Returns `{:ok, consent}`.
  """
  def record_consent(%User{} = user, %You.Admin.App{} = app, scopes) when is_list(scopes) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, You.Settings.get(:jwt_expiry_hours) * 3600, :second)

    result =
      %Consent{}
      |> Consent.changeset(%{
        user_id: user.id,
        app_id: app.id,
        scopes: scopes,
        granted_at: now,
        expires_at: expires_at
      })
      |> Repo.insert(
        on_conflict: {:replace, [:scopes, :granted_at, :expires_at]},
        conflict_target: [:user_id, :app_id]
      )

    :telemetry.execute([:you, :audit, :consent, :grant], %{}, %{
      user_id: user.id,
      app_id: app.id,
      scopes: scopes
    })

    result
  end

  @doc """
  Checks if a valid consent exists for the given user and app.
  Returns `{:ok, scopes}` or `{:error, :no_consent}`.
  """
  def check_consent(%User{} = user, %You.Admin.App{} = app) do
    now = DateTime.utc_now()

    case Repo.get_by(Consent, user_id: user.id, app_id: app.id) do
      %Consent{scopes: scopes, expires_at: expires_at} when not is_nil(expires_at) ->
        if DateTime.compare(expires_at, now) == :gt do
          {:ok, scopes}
        else
          {:error, :no_consent}
        end

      _ ->
        {:error, :no_consent}
    end
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
