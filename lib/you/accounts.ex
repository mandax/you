defmodule You.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias You.Repo

  alias You.Accounts.{
    User,
    UserToken,
    UserNotifier,
    RecoveryCode,
    Consent,
    FederatedIdentity,
    Passkey
  }

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
  Delivers the reset password instructions to the given user.
  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_url_fun)
      when is_function(reset_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    UserNotifier.deliver_reset_password_instructions(user, reset_url_fun.(encoded_token))
  end

  @doc """
  Gets the user by reset password token.
  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         {%User{} = user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Deletes all tokens for a given user.
  """
  def delete_all_user_tokens(%User{} = user) do
    Repo.delete_all(from(UserToken, where: [user_id: ^user.id]))
    :ok
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  @doc "Lists a user's active session tokens, newest first."
  def list_user_sessions(%User{id: user_id}) do
    Repo.all(
      from t in UserToken,
        where: t.user_id == ^user_id and t.context == "session",
        order_by: [desc: t.inserted_at]
    )
  end

  @doc """
  Revokes one of the user's sessions by token id. Scoped to the user, so a user
  can only end their own sessions. Returns the number deleted (0 or 1).
  """
  def delete_user_session(%User{id: user_id}, id) do
    {count, _} =
      Repo.delete_all(
        from t in UserToken,
          where: t.id == ^id and t.user_id == ^user_id and t.context == "session"
      )

    count
  end

  @doc "Revokes every session except the one holding `current_token`."
  def delete_other_user_sessions(%User{id: user_id}, current_token) do
    {count, _} =
      Repo.delete_all(
        from t in UserToken,
          where: t.user_id == ^user_id and t.context == "session" and t.token != ^current_token
      )

    count
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

  @doc "Issues a refresh token for the user carrying the granted scopes."
  def create_refresh_token(%User{} = user, scopes) do
    {token, user_token} = UserToken.build_refresh_token(user, scopes)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Rotates a refresh token: validates it, deletes it (single-use), and issues a
  fresh one for the same user and scopes. Returns
  `{:ok, user, scopes, new_token}` or `{:error, :invalid}`.
  """
  def rotate_refresh_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_refresh_token_query(token),
         {user, old_token} <- Repo.one(query) do
      scopes = parse_meta_scopes(old_token.meta)
      Repo.delete!(old_token)
      {:ok, user, scopes, create_refresh_token(user, scopes)}
    else
      _ -> {:error, :invalid}
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

  ## Federated Identity

  @doc """
  Finds or creates a user by federated identity.

  - If a `FederatedIdentity` already exists for the given provider + subject,
    returns the linked user (idempotent re-login).
  - If a user with the given email already exists, links the federated identity
    to that user (account linking).
  - Otherwise, creates a confirmed user with no password and creates the
    federated identity record.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def find_or_create_user_by_federated_identity(provider, subject, email)
      when is_binary(provider) and is_binary(subject) and is_binary(email) do
    case get_federated_identity(provider, subject) do
      %FederatedIdentity{} = fed ->
        {:ok, get_user!(fed.user_id)}

      nil ->
        case do_find_or_create(provider, subject, email) do
          {:ok, user} -> {:ok, user}
          {:error, _reason} -> {:error, :transaction_aborted}
        end
    end
  end

  defp do_find_or_create(provider, subject, email) do
    Repo.transact(fn ->
      user =
        case get_user_by_email(email) do
          %User{} = existing -> existing
          nil -> insert_confirmed_user!(email)
        end

      %FederatedIdentity{}
      |> FederatedIdentity.changeset(%{
        user_id: user.id,
        provider: provider,
        subject: subject,
        email: email
      })
      |> Repo.insert!()

      {:ok, user}
    end)
  end

  defp insert_confirmed_user!(email) do
    %User{}
    |> User.email_changeset(%{email: email})
    |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Repo.insert!()
  end

  @doc """
  Gets a federated identity by provider and subject.

  Returns `%FederatedIdentity{}` or `nil`.
  """
  def get_federated_identity(provider, subject)
      when is_binary(provider) and is_binary(subject) do
    Repo.get_by(FederatedIdentity, provider: provider, subject: subject)
  end

  @doc """
  Lists all federated identities for a given user.

  Returns a list of `%FederatedIdentity{}`.
  """
  def list_federated_identities_for_user(%User{} = user) do
    Repo.all(from(f in FederatedIdentity, where: f.user_id == ^user.id))
  end

  @doc """
  Deletes a federated identity by provider and subject.

  Returns the number of deleted rows (0 or 1).
  """
  def delete_federated_identity(provider, subject)
      when is_binary(provider) and is_binary(subject) do
    {count, _} =
      Repo.delete_all(
        from(f in FederatedIdentity, where: f.provider == ^provider and f.subject == ^subject)
      )

    count
  end

  @doc """
  Deletes a federated identity by id, scoped to the owning user.

  Returns `{count, nil}` — `{1, nil}` when unlinked, `{0, nil}` when the id
  does not exist or is not owned by this user.
  """
  def delete_user_federated_identity(%User{id: user_id}, id) do
    Repo.delete_all(
      from(f in FederatedIdentity, where: f.id == ^id and f.user_id == ^user_id)
    )
  end

  ## Passkeys (WebAuthn)

  @doc """
  Lists all passkeys registered for the given user, newest first.
  """
  def list_user_passkeys(%User{id: user_id}) do
    Repo.all(
      from p in Passkey,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at]
    )
  end

  @doc """
  Gets a passkey by its credential ID.

  Returns `%Passkey{}` or `nil`.
  """
  def get_passkey_by_credential_id(credential_id) when is_binary(credential_id) do
    Repo.get_by(Passkey, credential_id: credential_id)
  end

  @doc """
  Stores a verified WebAuthn credential for the given user.

  The `attrs` map may contain:
    - `:credential_id` — binary credential ID from the authenticator
    - `:public_key` — COSE key **map** (will be term_to_binary encoded) or already-encoded binary
    - `:sign_count` — initial sign count (usually 0 or 1)
    - `:label` — optional human-readable label
    - `:aaguid` — optional AAGUID from the authenticator

  Returns `{:ok, %Passkey{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  def register_passkey(%User{id: user_id}, attrs) do
    attrs =
      if is_map(attrs[:public_key]) do
        Map.put(attrs, :public_key, Passkey.encode_cose_key(attrs[:public_key]))
      else
        attrs
      end

    %Passkey{}
    |> Passkey.changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert()
  end

  @doc """
  Updates the sign count for a passkey after successful authentication.

  This is used for clone detection: if the stored sign count is ever *greater*
  than the one returned by the authenticator, the credential may have been
  cloned and should be rejected.
  """
  def update_passkey_sign_count(%Passkey{} = passkey, sign_count)
      when is_integer(sign_count) and sign_count >= 0 do
    passkey
    |> Ecto.Changeset.change(sign_count: sign_count)
    |> Repo.update()
  end

  @doc """
  Deletes a passkey, scoped to the owning user. Returns `{1, nil}` if
  deleted, `{0, nil}` if not found (or not owned by this user).
  """
  def delete_user_passkey(%User{id: user_id}, passkey_id) do
    Repo.delete_all(
      from p in Passkey,
        where: p.id == ^passkey_id and p.user_id == ^user_id
    )
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
