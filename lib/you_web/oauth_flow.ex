defmodule YouWeb.OAuthFlow do
  @moduledoc """
  Shared completion for every interactive login path (password, magic link,
  TOTP, and federated/social).

  If the browser session carries a registered consumer `callback_url` (stashed
  when the app redirected the user to `/users/log-in?callback_url=…`), the login
  is finished as an OAuth authorization-code redirect: record consent, mint a
  single-use code bound to the PKCE challenge, and 302 back to the consumer with
  the code + echoed `state`. Otherwise it's a plain first-party login into You.

  Centralizing this guarantees social login hands a code back to the requesting
  app exactly like the other methods, instead of stranding the user inside You.
  """
  use YouWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias You.Accounts
  alias YouWeb.UserAuth

  @doc """
  Completes a login for `user`. Redirects to the consumer's callback with an
  auth code when in an OAuth flow, otherwise logs the user into You.

  Set the flash before calling; this only handles the session + redirect.
  """
  def complete_login(conn, user, params \\ %{}) do
    case safe_callback_url(conn) do
      nil ->
        UserAuth.log_in_user(conn, user, params)

      callback_url ->
        record_consent_for_app(conn, user)
        # Capture the flow keys before create_user_session renews the session.
        scopes = get_session(conn, :scopes) || ["email"]
        state = get_session(conn, :state)
        code_challenge = get_session(conn, :code_challenge)

        {:ok, code} =
          Accounts.generate_auth_code(
            user,
            scopes,
            code_challenge,
            app_slug_for_callback(conn)
          )

        conn
        |> UserAuth.create_user_session(user, params)
        |> redirect_with_code(callback_url, code, state)
    end
  end

  @doc """
  Finishes an authorization for a user who is already signed in to You: record
  consent, mint a code, redirect back to the consumer.

  This is what the consent screen posts to, and what single-app mode calls
  instead of rendering that screen. Consent is recorded either way, so an
  instance that later flips to multi-app mode has no gap in its consent
  records.

  Returns `{:error, :no_callback}` when the session carries no registered
  callback URL, which is the caller's cue to send the user back to log in.
  """
  def authorize_signed_in(conn, user) do
    case safe_callback_url(conn) do
      nil ->
        {:error, :no_callback}

      callback_url ->
        record_consent_for_app(conn, user)
        scopes = get_session(conn, :scopes) || ["email"]
        state = get_session(conn, :state)

        {:ok, code} =
          Accounts.generate_auth_code(
            user,
            scopes,
            get_session(conn, :code_challenge),
            app_slug_for_callback(conn)
          )

        redirect_with_code(conn, callback_url, code, state)
    end
  end

  @doc """
  The session `callback_url`, but only if it exactly matches a registered app
  (exact match blocks open-redirect via a lookalike callback).
  """
  def safe_callback_url(conn) do
    with url when is_binary(url) <- get_session(conn, :callback_url),
         {:ok, _app} <- You.Admin.lookup_app_by_callback(url) do
      url
    else
      _ -> nil
    end
  end

  @doc """
  The slug of the registered app the session `callback_url` belongs to, or
  nil for first-party logins. Bound into auth codes so issued JWTs can carry
  per-app roles.
  """
  def app_slug_for_callback(conn) do
    with url when is_binary(url) <- get_session(conn, :callback_url),
         {:ok, app} <- You.Admin.lookup_app_by_callback(url) do
      app.slug
    else
      _ -> nil
    end
  end

  @doc "Records the user's consent for the app the callback_url belongs to."
  def record_consent_for_app(conn, user) do
    scopes = get_session(conn, :scopes) || ["email"]

    with url when is_binary(url) <- get_session(conn, :callback_url),
         {:ok, app} <- You.Admin.lookup_app_by_callback(url) do
      Accounts.record_consent(user, app, scopes)
    end

    :ok
  end

  @doc """
  Redirects to the consumer callback with the code, echoing `state` for CSRF,
  and clears the one-shot flow session keys.

  `state` is passed in, not read from the session: login renews the session
  (anti-fixation) before this runs, which wipes it; callers capture it first.
  """
  def redirect_with_code(conn, callback_url, code, state) do
    query =
      case state do
        nil -> URI.encode_query(code: code)
        state -> URI.encode_query(code: code, state: state)
      end

    conn
    |> put_session(:callback_url, nil)
    |> put_session(:scopes, nil)
    |> put_session(:state, nil)
    |> put_session(:code_challenge, nil)
    |> redirect(external: "#{callback_url}?#{query}")
  end
end
