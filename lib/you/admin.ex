defmodule You.Admin do
  @moduledoc """
  Admin operations: user management, app registration, settings.
  """

  import Ecto.Query, warn: false
  alias You.Repo
  alias You.Accounts.{User, Passkey, FederatedIdentity}
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
    |> App.changeset(attrs)
    |> Ecto.Changeset.put_change(:client_secret_hash, hashed)
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
    |> Ecto.Changeset.change(client_secret_hash: hashed)
    |> Repo.update()
    |> case do
      {:ok, app} -> {:ok, app, secret}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Fetches a single user by id, raising if not found.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Lists all users.
  """
  def list_users do
    Repo.all(from u in User, order_by: [asc: u.email])
  end

  @doc """
  Lists all users with their passkey and federated-identity counts.

  Returns a list of `%{user:, passkeys:, identities:}` maps, ordered by email.
  Counts are gathered in two grouped queries (no N+1).
  """
  def list_users_with_stats do
    users = Repo.all(from u in User, order_by: [asc: u.email])

    passkey_counts =
      Map.new(Repo.all(from p in Passkey, group_by: p.user_id, select: {p.user_id, count(p.id)}))

    identity_counts =
      Map.new(
        Repo.all(
          from f in FederatedIdentity, group_by: f.user_id, select: {f.user_id, count(f.id)}
        )
      )

    Enum.map(users, fn u ->
      %{
        user: u,
        passkeys: Map.get(passkey_counts, u.id, 0),
        identities: Map.get(identity_counts, u.id, 0)
      }
    end)
  end

  @doc """
  Bootstraps the first admin user. Creates the user if needed, sets is_admin.
  Idempotent: returns `{:ok, user}` if already an admin.
  """
  def bootstrap_admin(email, password) do
    user =
      case Repo.get_by(User, email: email) do
        nil ->
          {:ok, user} = You.Accounts.register_user(%{email: email})

          # Bypasses changeset min-length for dev convenience.
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
  Fetches a single app by id, raising if it does not exist.
  """
  def get_app!(id), do: Repo.get!(App, id)

  @doc """
  Fetches a single app by slug (its client_id), raising if it does not exist.
  """
  def get_app_by_slug!(slug) when is_binary(slug), do: Repo.get_by!(App, slug: slug)

  @doc """
  Updates an existing app's attributes.

  Returns `{:ok, app}` or `{:error, changeset}`.
  """
  def update_app(%App{} = app, attrs) do
    result =
      app
      |> App.changeset(attrs)
      |> Repo.update()

    :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
      action: "update_app",
      app_slug: app.slug
    })

    result
  end

  @doc """
  Replaces the app's `allowed_roles`.

  Refuses to drop a role that users are still assigned, since those users would
  keep a role the app no longer recognises. Returns `{:ok, app}`,
  `{:error, {:roles_in_use, roles}}`, or `{:error, changeset}`.
  """
  def update_allowed_roles(%App{} = app, roles) when is_list(roles) do
    roles = roles |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    in_use = Map.keys(You.Roles.count_by_role(app))

    case Enum.reject(in_use, &(&1 in roles)) do
      [] -> update_app(app, %{"allowed_roles" => roles})
      stranded -> {:error, {:roles_in_use, Enum.sort(stranded)}}
    end
  end

  @doc """
  Deletes a registered app. Returns `{:ok, app}` or `{:error, changeset}`.
  """
  def delete_app(%App{} = app) do
    result = Repo.delete(app)

    :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
      action: "delete_app",
      app_slug: app.slug
    })

    result
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
