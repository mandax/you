defmodule You.Admin do
  @moduledoc """
  Admin operations: user management, app registration, settings.
  """

  import Ecto.Query, warn: false
  alias You.Repo
  alias You.Accounts.{User, Passkey, FederatedIdentity, Consent}
  alias You.Admin.App
  alias You.Roles.Assignment

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
      {:ok, app} ->
        You.Mode.invalidate_app_cache()
        {:ok, app, secret}

      {:error, changeset} ->
        {:error, changeset}
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
      {:ok, app} ->
        You.Mode.invalidate_app_cache()

        # Rotation invalidates the live secret immediately, so it needs a trail
        # of its own rather than inheriting `update_app`'s.
        :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
          action: "rotate_app_secret",
          app_slug: app.slug
        })

        {:ok, app, secret}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Fetches a single user by id, raising if not found.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Lists users, ordered by email.

  `:limit` and `:offset` page the result; unpaged callers get everything, which
  is fine for the console but not for an API answering an unbounded request.
  """
  def list_users(opts \\ []) do
    from(u in User, order_by: [asc: u.email]) |> paginate(opts) |> Repo.all()
  end

  defp paginate(query, opts) do
    case opts[:limit] do
      nil -> query
      limit -> from(q in query, limit: ^limit, offset: ^(opts[:offset] || 0))
    end
  end

  @doc "How many users exist."
  def count_users, do: Repo.aggregate(User, :count)

  @doc "How many users are You admins."
  def count_admins, do: Repo.aggregate(from(u in User, where: u.is_admin), :count)

  @doc """
  Lists users matching `filters`, with their passkey and federated-identity
  counts, ordered by email. `:limit`/`:offset` in `opts` page the result
  exactly like `list_users/1`; unpaged, this is the whole-instance shape
  `list_users_with_stats/0` used to be.

  Passkey and identity counts are scoped to exactly the users this call
  returns (two grouped queries, no N+1) — a caller paging through the console
  filters and pages first, so the count queries never touch a passkey or
  identity belonging to a user outside the current page.

  `filters` (a map, all keys optional):
    * `:email` — literal substring match, with no pattern language: `%` and
      `_` match themselves. Case-insensitive for ASCII only, so `JOSÉ` will
      not find `josé`.
    * `:status` — `"confirmed"` or `"unconfirmed"`
    * `:app_id` — the user has an explicit role assignment in this app
    * `:role` — the user has an **explicit assignment** of this role, in some
      app or (with `:app_id`) in that one. Deliberately not the *effective*
      role: `Roles.role_for/2` falls back to the app's `default_role`, so
      every unassigned user effectively holds it, and matching that would
      make the app's default role select the entire instance. Filtering by a
      role nobody has been explicitly given returns nothing, which is the
      honest answer to "who did we grant this to".
  """
  def list_users_with_stats(filters \\ %{}, opts \\ []) do
    users = filters |> filtered_users_query() |> paginate(opts) |> Repo.all()
    ids = Enum.map(users, & &1.id)

    passkey_counts = counts_by_user(Passkey, ids)
    identity_counts = counts_by_user(FederatedIdentity, ids)

    Enum.map(users, fn u ->
      %{
        user: u,
        passkeys: Map.get(passkey_counts, u.id, 0),
        identities: Map.get(identity_counts, u.id, 0)
      }
    end)
  end

  @doc "Counts the users matching `filters` (see `list_users_with_stats/2`)."
  def count_users_matching(filters \\ %{}) do
    filters |> filtered_users_query() |> exclude(:order_by) |> Repo.aggregate(:count)
  end

  defp filtered_users_query(filters) do
    from(u in User, order_by: [asc: u.email])
    |> filter_by_email(Map.get(filters, :email))
    |> filter_by_status(Map.get(filters, :status))
    |> filter_by_app_role(Map.get(filters, :app_id), Map.get(filters, :role))
  end

  defp filter_by_email(query, nil), do: query

  # Not `LIKE`: it would make `%` and `_` typed into the filter box into
  # wildcards, and escaping them needs an ESCAPE clause SQLite will not accept
  # as a bound parameter. `instr` has nothing to escape.
  defp filter_by_email(query, email) do
    from(u in query, where: fragment("instr(lower(?), lower(?)) > 0", u.email, ^email))
  end

  defp filter_by_status(query, "confirmed"),
    do: from(u in query, where: not is_nil(u.confirmed_at))

  defp filter_by_status(query, "unconfirmed"), do: from(u in query, where: is_nil(u.confirmed_at))
  defp filter_by_status(query, _), do: query

  defp filter_by_app_role(query, nil, nil), do: query

  defp filter_by_app_role(query, app_id, role) do
    condition = assignment_condition(app_id, role)

    from(u in query,
      where: u.id in subquery(from(a in Assignment, where: ^condition, select: a.user_id))
    )
  end

  defp assignment_condition(nil, role), do: dynamic([a], a.role == ^role)
  defp assignment_condition(app_id, nil), do: dynamic([a], a.app_id == ^app_id)

  defp assignment_condition(app_id, role),
    do: dynamic([a], a.app_id == ^app_id and a.role == ^role)

  defp counts_by_user(_schema, []), do: %{}

  defp counts_by_user(schema, ids) do
    Map.new(
      Repo.all(
        from r in schema,
          where: r.user_id in ^ids,
          group_by: r.user_id,
          select: {r.user_id, count(r.id)}
      )
    )
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

  @doc "How many apps are registered."
  def count_apps, do: Repo.aggregate(App, :count)

  @doc """
  Apps whose slug does not satisfy the format `App.changeset/2` now enforces.

  A legacy row keeps its non-conforming slug until something touches the
  slug itself — an unrelated field update still succeeds, since changesets
  only validate a field that is actually changing. What breaks on such a
  row: renaming it fails validation, importing a configuration bundle that
  carries it from a pre-validation instance silently skips the app rather than
  failing, and the non-conforming value is already live everywhere a slug is
  used — the `client_id` a consumer configures,
  authorize URLs, and the role-resolution key. `mix you.audit_slugs` and
  `You.Release.audit_slugs/0` report these before whoever runs this instance
  hits one of those.
  """
  def apps_with_invalid_slug do
    Enum.filter(list_apps(), &App.invalid_slug?(&1.slug))
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
  Fetches a single app by slug, or nil. For callers where an unknown slug is
  an ordinary outcome rather than a bug — a preview link someone edited, say.
  """
  def get_app_by_slug(slug) when is_binary(slug), do: Repo.get_by(App, slug: slug)

  @doc """
  How long the JWTs issued for `app` live, in seconds.

  Accepts an `App`, a slug, or nil — the token-issuing paths variously hold
  one of the three, and an unknown slug falls back to the instance setting
  rather than raising: refusing to issue a token because an app row was
  deleted mid-flow would be a worse failure than a default lifetime.
  """
  def jwt_expiry_seconds(app_or_slug),
    do: resolve_app(app_or_slug) |> App.resolved_jwt_expiry_hours() |> Kernel.*(3600)

  @doc "How long the authorization codes issued for `app` live, in minutes."
  def code_expiry_minutes(app_or_slug),
    do: resolve_app(app_or_slug) |> App.resolved_code_expiry_minutes()

  defp resolve_app(%App{} = app), do: app
  defp resolve_app(slug) when is_binary(slug), do: get_app_by_slug(slug)
  defp resolve_app(_), do: nil

  @doc """
  The longest JWT lifetime any app on this instance can produce, in hours.

  What instance-wide retention has to be measured against: the JTI blocklist
  is pruned on a single clock, and pruning on the instance default alone would
  drop revocations while an app with a longer lifetime still has live tokens
  carrying those JTIs — a revoked token would start working again.
  """
  def max_jwt_expiry_hours do
    max_expiry(:jwt_expiry_hours)
  end

  @doc """
  The longest authorization-code lifetime any app can produce, in minutes.
  Used to bound the lookup before an individual code is checked against its
  own app's expiry.
  """
  def max_code_expiry_minutes do
    max_expiry(:code_expiry_minutes)
  end

  defp max_expiry(key) do
    instance = You.Settings.get(key)

    case Repo.one(from a in App, select: max(field(a, ^key))) do
      nil -> instance
      configured -> max(instance, configured)
    end
  end

  @doc """
  Updates an existing app's attributes.

  Returns `{:ok, app}` or `{:error, changeset}`.
  """
  def update_app(%App{} = app, attrs) do
    result =
      app
      |> App.changeset(attrs)
      |> Repo.update()

    # Only on success: a rejected changeset that still emitted would put a
    # change into the audit trail that never happened.
    with {:ok, _} <- result do
      You.Mode.invalidate_app_cache()

      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "update_app",
        app_slug: app.slug
      })
    end

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
    current = app.allowed_roles || []

    with [] <- Enum.reject(in_use, &(&1 in roles)),
         {:ok, updated} <- update_app(app, %{"allowed_roles" => roles}) do
      # Which roles moved, not just that the app changed: the generic
      # `update_app` event cannot say what was granted or taken away.
      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "update_allowed_roles",
        app_slug: app.slug,
        added: roles -- current,
        removed: current -- roles
      })

      {:ok, updated}
    else
      {:error, changeset} -> {:error, changeset}
      stranded -> {:error, {:roles_in_use, Enum.sort(stranded)}}
    end
  end

  @doc """
  Sets the role unassigned users resolve to in this app.

  Emitted as its own audit action rather than a generic `update_app`: changing
  it re-roles every user without an explicit assignment on their next token,
  with no per-user record of the change anywhere.
  """
  def set_default_role(%App{} = app, role) when is_binary(role) do
    result = update_app(app, %{"default_role" => role})

    with {:ok, updated} <- result do
      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "set_default_role",
        app_slug: app.slug,
        from: app.default_role,
        to: updated.default_role
      })
    end

    result
  end

  @doc """
  Counts the rows that cascade-delete along with the app: consents and role
  assignments. Surfaced in the delete confirmation so an admin sees the
  blast radius before confirming, since both tables `on_delete: :delete_all`
  silently.
  """
  def deletion_impact(%App{} = app) do
    %{
      consents: Repo.aggregate(from(c in Consent, where: c.app_id == ^app.id), :count),
      role_assignments: Repo.aggregate(from(a in Assignment, where: a.app_id == ^app.id), :count)
    }
  end

  @doc """
  Deletes a registered app. Returns `{:ok, app}` or `{:error, changeset}`.
  """
  def delete_app(%App{} = app) do
    result = Repo.delete(app)

    # Only on success, matching every other mutator here. A failed delete that
    # still emitted would put an app removal into the trail that never happened.
    with {:ok, _} <- result do
      You.Mode.invalidate_app_cache()

      :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
        action: "delete_app",
        app_slug: app.slug
      })
    end

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
