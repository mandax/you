defmodule You.Admin do
  @moduledoc """
  Admin operations: user management, app registration, settings.
  """

  import Ecto.Query, warn: false
  alias You.Repo
  alias You.Accounts.User
  alias You.Admin.App

  require Bcrypt

  @doc """
  Promotes a user to admin. Returns `{:ok, user}`.
  """
  def promote_admin(%User{} = user) do
    result =
      user
      |> Ecto.Changeset.change(is_admin: true)
      |> Repo.update()

    :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
      action: "promote_admin",
      target_user_id: user.id,
      target_email: user.email
    })

    result
  end

  @doc """
  Promotes a user to admin, raising on error.
  """
  def promote_admin!(%User{} = user) do
    {:ok, user} = promote_admin(user)
    user
  end

  @doc """
  Demotes an admin. Returns `{:ok, user}`.
  """
  def demote_admin(%User{} = user) do
    user
    |> Ecto.Changeset.change(is_admin: false)
    |> Repo.update()
  end

  @hash_algorithm :sha256
  @rand_size 32

  @doc """
  Registers a new app. Generates a client secret, stores its SHA-256 hash,
  and returns the plaintext secret once.

  Returns `{:ok, app, client_secret}` or `{:error, changeset}`.
  """
  def create_app(attrs) do
    secret = :crypto.strong_rand_bytes(@rand_size) |> Base.url_encode64(padding: false)
    hashed = :crypto.hash(@hash_algorithm, secret)

    %App{}
    |> App.changeset(Map.put(attrs, :client_secret_hash, hashed))
    |> Repo.insert()
    |> case do
      {:ok, app} -> {:ok, app, secret}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Rotates the client secret for an existing app. Stores the new hash and
  returns the plaintext secret once.

  Returns `{:ok, app, new_secret}` or `{:error, changeset}`.
  """
  def rotate_app_secret(%App{} = app) do
    secret = :crypto.strong_rand_bytes(@rand_size) |> Base.url_encode64(padding: false)
    hashed = :crypto.hash(@hash_algorithm, secret)

    app
    |> App.changeset(%{client_secret_hash: hashed})
    |> Repo.update()
    |> case do
      {:ok, app} -> {:ok, app, secret}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Lists all users.
  """
  def list_users do
    Repo.all(User)
  end

  @doc """
  Bootstraps the first admin user. Creates the user if needed, sets is_admin.
  Idempotent — returns `{:ok, user}` if already an admin.
  """
  def bootstrap_admin(email, password) do
    user =
      case Repo.get_by(User, email: email) do
        nil ->
          {:ok, user} = You.Accounts.register_user(%{email: email})

          # Set password + confirm directly (bypasses changeset min-length for dev convenience)
          hashed = Bcrypt.hash_pwd_salt(password)

          {:ok, user} =
            user
            |> Ecto.Changeset.change(
              hashed_password: hashed,
              confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
            )
            |> You.Repo.update()

          user

        existing ->
          existing
      end

    if user.is_admin do
      {:ok, user}
    else
      promote_admin(user)
    end
  end

  @doc """
  Lists all registered apps.
  """
  def list_apps do
    Repo.all(App)
  end

  @doc """
  Finds the registered app whose callback URL is an exact match for the given URL.
  Returns `{:ok, app}` or `:error`.

  Exact match, not prefix: a prefix match lets a registered `https://app.com/cb`
  approve a redirect to `https://app.com/cb.attacker.com/…`, i.e. an open
  redirect that leaks the auth code. Consumers must register their exact
  callback URL.
  """
  def lookup_app_by_callback(callback_url) when is_binary(callback_url) do
    case Repo.get_by(App, callback_url: callback_url) do
      nil -> :error
      app -> {:ok, app}
    end
  end
end
