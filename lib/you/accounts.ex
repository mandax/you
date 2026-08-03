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
    Passkey,
    RevokedJti
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
    result =
      %User{}
      |> User.email_changeset(attrs)
      |> Repo.insert()

    with {:ok, user} <- result do
      :telemetry.execute([:you, :audit, :user, :registered], %{}, %{
        user_id: user.id,
        email: user.email
      })
    end

    result
  end

  @doc """
  Registers a user with email and password, confirmed immediately.

  Used by the management API: an admin-created account must be usable
  right away, without the magic-link confirmation round-trip. Atomic:
  either the whole account exists or nothing does.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def register_user_with_password(attrs) do
    # The password changeset is built before the transaction opens. Building it
    # runs the pwned-password check — a live HTTP call with a 3s timeout — and
    # bcrypt, and SQLite has one writer: doing that under an open write lock
    # blocks every other writer on the instance for the duration.
    password_changeset = prepare_password(attrs)

    Repo.transact(fn ->
      with {:ok, user} <- register_user(attrs),
           {:ok, {user, _tokens}} <- apply_password(user, password_changeset),
           {:ok, user} <- confirm_user(user) do
        {:ok, user}
      end
    end)
  end

  @doc """
  Builds a password changeset without touching the database.

  Hashing and the pwned-password check are the slow parts of setting a
  password; doing them before a write transaction opens keeps SQLite's single
  writer free while they run. Pair with `apply_password/2`.
  """
  def prepare_password(attrs), do: User.password_changeset(%User{}, attrs)

  @doc "Applies a changeset built by `prepare_password/1` to `user`."
  def apply_password(user, %Ecto.Changeset{valid?: false} = changeset) do
    {:error, %{changeset | data: user, action: :insert}}
  end

  def apply_password(user, changeset) do
    user
    |> Ecto.Changeset.change(Map.take(changeset.changes, [:hashed_password]))
    |> update_user_and_delete_all_tokens()
  end

  # Mirrors the confirmation done by the magic-link login: stamp
  # confirmed_at so the account is considered proven.
  defp confirm_user(user) do
    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
    |> Repo.update()
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

  `from_name` sets the sender name, so mail sent as part of an app's login
  flow arrives under that app's name rather than You's. `nil` keeps the
  default.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun, from_name \\ nil)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token), from_name)
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

  @doc "Lists a user's active session tokens, newest first. Expired tokens are hidden."
  def list_user_sessions(%User{id: user_id}) do
    threshold =
      DateTime.add(DateTime.utc_now(), -You.Settings.get(:session_expiry_hours) * 3600, :second)

    Repo.all(
      from t in UserToken,
        where: t.user_id == ^user_id and t.context == "session" and t.inserted_at > ^threshold,
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

  Pass `code_challenge` (base64url SHA-256 of the client's code_verifier) to
  bind the code to a PKCE verifier that must be presented at exchange time.

  Pass `app_slug` when the code is issued for a known app; it is returned by
  `consume_auth_code/2` and drives per-app role claims in the issued JWT.
  """
  def generate_auth_code(%User{} = user, scopes \\ nil, code_challenge \\ nil, app_slug \\ nil) do
    {code, user_token} = UserToken.build_auth_token(user, scopes, code_challenge, app_slug)
    Repo.insert!(user_token)
    {:ok, code}
  end

  @doc """
  Consumes an authorization code, returning the user if valid.

  The redeeming client must prove it is entitled to the code, one of two ways:

    * PKCE — the code was issued with a `code_challenge` and the caller presents
      a `code_verifier` satisfying
      `base64url(sha256(code_verifier)) == code_challenge`.
    * Client authentication — the caller has already verified a confidential
      client's secret (or is trusted by transport, as over Erlang distribution)
      and passes `client_authenticated: true`.

  A code issued without a challenge is redeemable **only** by an authenticated
  client. The code is single-use; it is always deleted once found, so a failed
  verification cannot be retried.

  Returns `{:ok, user, scopes, app_slug}`, `{:error, :invalid_grant}` (PKCE
  failure), `{:error, :invalid_client}` (neither proof presented), or
  `{:error, :not_found}`.
  """
  def consume_auth_code(code, code_verifier \\ nil, opts \\ []) when is_binary(code) do
    expiry = You.Settings.get(:code_expiry_minutes)
    authenticated? = Keyword.get(opts, :client_authenticated, false)

    with {:ok, query} <- UserToken.verify_auth_code_query(code, expiry) do
      case Repo.one(query) do
        {user, token} ->
          meta = parse_meta(token.meta)
          Repo.delete!(token)

          case code_proof(meta["code_challenge"], code_verifier, authenticated?) do
            :ok -> {:ok, user, meta["scopes"] || ["email"], meta["app"]}
            {:error, reason} -> {:error, reason}
          end

        nil ->
          {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp parse_meta(nil), do: %{}

  defp parse_meta(meta) when is_binary(meta) do
    case Jason.decode(meta) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp code_proof(nil, _verifier, true), do: :ok
  defp code_proof(nil, _verifier, _authenticated?), do: {:error, :invalid_client}

  defp code_proof(challenge, verifier, _authenticated?) do
    if pkce_ok?(challenge, verifier), do: :ok, else: {:error, :invalid_grant}
  end

  defp pkce_ok?(_challenge, verifier) when not is_binary(verifier), do: false

  defp pkce_ok?(challenge, verifier) do
    computed = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(computed, challenge)
  end

  @doc "Issues a refresh token for the user carrying the granted scopes and app."
  def create_refresh_token(%User{} = user, scopes, app_slug \\ nil) do
    {token, user_token} = UserToken.build_refresh_token(user, scopes, app_slug)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Rotates a refresh token: validates it, deletes it (single-use), and issues a
  fresh one for the same user and scopes. Returns
  `{:ok, user, scopes, new_token, app_slug}` or `{:error, :invalid}`.
  """
  def rotate_refresh_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_refresh_token_query(token),
         {user, old_token} <- Repo.one(query) do
      meta = parse_meta(old_token.meta)
      scopes = meta["scopes"] || ["email"]
      app_slug = meta["app"]
      Repo.delete!(old_token)
      {:ok, user, scopes, create_refresh_token(user, scopes, app_slug), app_slug}
    else
      _ -> {:error, :invalid}
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
  Disables TOTP for a user: clears the secret and enabled flag and removes all
  of the user's recovery codes. Returns `{:ok, user}`.
  """
  def disable_totp(%User{} = user) do
    Repo.transact(fn ->
      Repo.delete_all(from r in RecoveryCode, where: r.user_id == ^user.id)

      user
      |> Ecto.Changeset.change(totp_enabled: false, totp_secret: nil)
      |> Repo.update()
    end)
  end

  @doc """
  Regenerates a user's recovery codes, replacing the entire existing set.

  Every existing code is deleted first, used or not, and a fresh set of 8 is
  issued in its place. A code that was never used is gone just as surely as
  one that was: this is the only way to recover from a low or exhausted set
  without disabling and re-enrolling TOTP from scratch.

  Requires TOTP to already be enabled. Emits an account-level audit event,
  since regenerating invalidates every code that came before it.

  Returns `{:ok, [string]}` or `{:error, :totp_not_enabled}`.
  """
  def regenerate_recovery_codes(%User{totp_enabled: true} = user) do
    result =
      Repo.transact(fn ->
        Repo.delete_all(from r in RecoveryCode, where: r.user_id == ^user.id)
        {:ok, generate_recovery_codes(user)}
      end)

    with {:ok, _codes} <- result do
      :telemetry.execute([:you, :audit, :account, :update], %{}, %{
        user_id: user.id,
        action: "regenerate_recovery_codes"
      })
    end

    result
  end

  def regenerate_recovery_codes(%User{}), do: {:error, :totp_not_enabled}

  ## Email 2FA (one-time code emailed as a second factor)

  @email_2fa_validity_minutes 10

  @doc "Turns on email-based 2FA (a code emailed at each password login)."
  def enable_email_2fa(%User{} = user) do
    user |> Ecto.Changeset.change(email_2fa_enabled: true) |> Repo.update()
  end

  @doc "Turns off email-based 2FA and clears any outstanding codes."
  def disable_email_2fa(%User{} = user) do
    Repo.delete_all(
      from t in UserToken, where: t.user_id == ^user.id and t.context == "email_2fa"
    )

    user |> Ecto.Changeset.change(email_2fa_enabled: false) |> Repo.update()
  end

  @doc """
  Generates a fresh 6-digit email 2FA code, stores its hash (superseding any
  previous one), and emails the plaintext code to the user. Returns `:ok`.
  """
  def send_email_2fa_code(%User{} = user) do
    code = generate_numeric_code(6)
    hash = :crypto.hash(:sha256, code)

    Repo.delete_all(
      from t in UserToken, where: t.user_id == ^user.id and t.context == "email_2fa"
    )

    Repo.insert!(%UserToken{
      token: hash,
      context: "email_2fa",
      sent_to: user.email,
      user_id: user.id
    })

    UserNotifier.deliver_email_2fa_code(user, code)
    :ok
  end

  @doc """
  Verifies an email 2FA code. On success the code is consumed (single-use).
  Returns `:ok` or `{:error, :invalid_code}`.
  """
  def verify_email_2fa_code(%User{} = user, code) when is_binary(code) do
    hash = :crypto.hash(:sha256, code)
    cutoff = DateTime.add(DateTime.utc_now(), -@email_2fa_validity_minutes * 60, :second)

    query =
      from t in UserToken,
        where:
          t.user_id == ^user.id and t.context == "email_2fa" and
            t.token == ^hash and t.inserted_at > ^cutoff

    case Repo.one(query) do
      nil -> {:error, :invalid_code}
      token -> Repo.delete!(token) && :ok
    end
  end

  defp generate_numeric_code(digits) do
    max = Integer.pow(10, digits)

    :crypto.strong_rand_bytes(8)
    |> :binary.decode_unsigned()
    |> rem(max)
    |> Integer.to_string()
    |> String.pad_leading(digits, "0")
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

    with {:ok, updated} <- result do
      :telemetry.execute([:you, :audit, :user, :anonymized], %{}, %{user_id: updated.id})
    end

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

  @doc """
  Verifies a recovery code for a user and consumes it on success (single-use).

  Checks the code against every unused recovery code the user has, since each
  is hashed with its own bcrypt salt and cannot be looked up directly. Runs a
  dummy `Bcrypt.no_user_verify/0` whenever there is no match — including when
  the user has no unused codes left — so a failed attempt takes the same time
  either way and doesn't leak whether the user has recovery codes remaining.

  Returns `{:ok, user}` or `{:error, :invalid_code}`.
  """
  def verify_recovery_code(%User{} = user, code) when is_binary(code) do
    unused_codes =
      Repo.all(from r in RecoveryCode, where: r.user_id == ^user.id and r.used == false)

    case Enum.find(unused_codes, &Bcrypt.verify_pass(code, &1.code_hash)) do
      nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid_code}

      matched_code ->
        claim_recovery_code(matched_code, user)
    end
  end

  # Single-use is decided by the update itself, not by the read above: two
  # requests carrying the same code can both see it unused, and only the one
  # that flips the row may be let through.
  defp claim_recovery_code(matched_code, user) do
    {claimed, _} =
      Repo.update_all(
        from(r in RecoveryCode, where: r.id == ^matched_code.id and r.used == false),
        set: [used: true]
      )

    if claimed == 1, do: {:ok, user}, else: {:error, :invalid_code}
  end

  @doc """
  Returns how many unused recovery codes a user has left.
  """
  def count_unused_recovery_codes(%User{} = user) do
    Repo.aggregate(
      from(r in RecoveryCode, where: r.user_id == ^user.id and r.used == false),
      :count
    )
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

    Repo.delete_all(from r in RevokedJti, where: r.inserted_at < ^threshold)
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
        on_conflict: {:replace, [:scopes, :granted_at, :expires_at, :updated_at]},
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
  Lists the distinct apps a user has an active (non-expired) consent for,
  most-recently-granted first.

  Returns a list of `%You.Admin.App{}` structs.
  """
  def list_consented_apps(%User{id: user_id}) do
    now = DateTime.utc_now()

    Repo.all(
      from c in Consent,
        join: a in You.Admin.App,
        on: c.app_id == a.id,
        where: c.user_id == ^user_id and c.expires_at > ^now,
        order_by: [desc: c.granted_at],
        select: a
    )
  end

  @doc """
  Revokes all access the user granted to a given app.

  Deletes the user's consent row(s) for the app. Scoped to the user;
  other users' consents for the same app are untouched.

  Returns `{count, nil}` where count is the number of consents deleted.
  """
  def revoke_app_access(%User{id: user_id}, app_id) do
    Repo.delete_all(
      from c in Consent,
        where: c.user_id == ^user_id and c.app_id == ^app_id
    )
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
    to that user **only when the IdP asserts the email is verified**. Linking to
    a pre-existing (typically password) account by email alone is an
    account-takeover vector: an attacker who controls an unverified IdP account
    matching a victim's email could otherwise hijack it. Unverified → returns
    `{:error, :email_not_verified}` (the user must link explicitly while logged in).
  - Otherwise, creates a user (confirmed only when the email is verified).

  Pass `email_verified` from the IdP's `email_verified` claim.

  Returns `{:ok, user}`, `{:error, :email_not_verified}`, or `{:error, reason}`.
  """
  def find_or_create_user_by_federated_identity(provider, subject, email, email_verified \\ false)
      when is_binary(provider) and is_binary(subject) and is_binary(email) do
    case get_federated_identity(provider, subject) do
      %FederatedIdentity{} = fed ->
        {:ok, get_user!(fed.user_id)}

      nil ->
        case get_user_by_email(email) do
          %User{} = existing ->
            if email_verified do
              link_federated_identity(existing, provider, subject, email)
            else
              {:error, :email_not_verified}
            end

          nil ->
            create_user_with_federated_identity(provider, subject, email, email_verified)
        end
    end
  end

  defp link_federated_identity(%User{} = user, provider, subject, email) do
    case insert_federated_identity(user, provider, subject, email) do
      {:ok, _} -> {:ok, user}
      {:error, _} -> {:error, :link_failed}
    end
  end

  defp create_user_with_federated_identity(provider, subject, email, email_verified) do
    Repo.transact(fn ->
      user = insert_federated_user!(email, email_verified)
      {:ok, _} = insert_federated_identity(user, provider, subject, email)
      {:ok, user}
    end)
  end

  defp insert_federated_identity(%User{id: user_id}, provider, subject, email) do
    %FederatedIdentity{}
    |> FederatedIdentity.changeset(%{
      user_id: user_id,
      provider: provider,
      subject: subject,
      email: email
    })
    |> Repo.insert()
  end

  # A brand-new account has no existing credentials to hijack, so creation is
  # allowed even for an unverified email, but it stays unconfirmed until proven.
  defp insert_federated_user!(email, email_verified) do
    changeset = User.email_changeset(%User{}, %{email: email})

    changeset =
      if email_verified,
        do: Ecto.Changeset.put_change(changeset, :confirmed_at, DateTime.utc_now(:second)),
        else: changeset

    Repo.insert!(changeset)
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

  Returns `{count, nil}`: `{1, nil}` when unlinked, `{0, nil}` when the id
  does not exist or is not owned by this user.
  """
  def delete_user_federated_identity(%User{id: user_id}, id) do
    Repo.delete_all(from(f in FederatedIdentity, where: f.id == ^id and f.user_id == ^user_id))
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
    - `:credential_id`: binary credential ID from the authenticator
    - `:public_key`: COSE key **map** (will be term_to_binary encoded) or already-encoded binary
    - `:sign_count`: initial sign count (usually 0 or 1)
    - `:label`: optional human-readable label
    - `:aaguid`: optional AAGUID from the authenticator

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
        {_count, tokens_to_expire} =
          Repo.delete_all(from(t in UserToken, where: t.user_id == ^user.id, select: t))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
