defmodule You.Invitations do
  @moduledoc """
  Admin-issued invitations: onboarding one named person, which registration
  and a SCIM push from an upstream directory both fail to cover.

  An invitation names an email, optionally an app, and optionally the role the
  invitee should hold in it. Accepting proves control of that mailbox, so it is
  treated exactly like a magic link — it confirms the account and signs the
  user in, and an account with a second factor enrolled still meets it
  (`YouWeb.SecondFactor`). What acceptance adds on top is the role.

  ## What an invitation is not

  It is not a way to gain access to an account that already exists on stronger
  terms than the mailbox already gives. Anyone holding the emailed link
  controls that inbox, and an inbox already reaches any of these accounts via
  the magic-link flow; the invitation grants the *role*, and the second-factor
  gate is what stops the link from being a login on its own.

  Tokens are stored as SHA-256 hashes, so a database read yields no working
  link, and acceptance is single-use.
  """

  import Ecto.Query, warn: false

  alias You.Accounts
  alias You.Accounts.User
  alias You.Admin
  alias You.Admin.App
  alias You.Invitations.Invitation
  alias You.Repo

  @rand_size 32
  @hash_algorithm :sha256
  @validity_in_days 7

  @doc "How long an invitation stays acceptable, in days."
  def validity_in_days, do: @validity_in_days

  @doc """
  Creates an invitation and returns `{:ok, invitation, token}`.

  The plaintext token is returned once, for the email; only its hash is
  stored. `attrs` takes `:email`, and optionally `:app_id`, `:role` and
  `:invited_by_id`.

  A role is refused unless the named app allows it, so an invitation can never
  promise access the app would reject on assignment.
  """
  def create(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    token = :crypto.strong_rand_bytes(@rand_size)

    with :ok <- validate_role(attrs),
         {:ok, invitation} <-
           %Invitation{}
           |> Invitation.changeset(Map.put(attrs, "token", :crypto.hash(@hash_algorithm, token)))
           |> Repo.insert() do
      invitation = Repo.preload(invitation, :app)
      audit(invitation, "invite_user")

      {:ok, invitation, Base.url_encode64(token, padding: false)}
    end
  end

  # Issuing, withdrawing and accepting an invitation are each as privileged as
  # the `set_role` they stand in for, and the `set_role` event that acceptance
  # eventually fires does not say an invitation was behind it — so without
  # these, nobody can reconstruct who invited whom to what.
  defp audit(%Invitation{} = invitation, action) do
    :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
      admin_user_id: invitation.invited_by_id,
      action: action,
      app_slug: invitation.app && invitation.app.slug,
      target: invitation.email,
      role: invitation.role
    })
  end

  defp validate_role(%{"role" => role} = attrs) when is_binary(role) and role != "" do
    case attrs["app_id"] && Repo.get(App, attrs["app_id"]) do
      %App{allowed_roles: allowed} ->
        if role in (allowed || ["user", "admin"]), do: :ok, else: {:error, :invalid_role}

      _ ->
        {:error, :role_without_app}
    end
  end

  defp validate_role(_attrs), do: :ok

  @doc """
  Creates an invitation and emails it. `url_fun` turns the token into the
  acceptance URL.

  Returns `{:ok, invitation}`. The email is sent outside any transaction the
  caller might hold: SQLite has one writer, and SMTP is not something to hold
  a write lock across.
  """
  def invite(attrs, url_fun) when is_function(url_fun, 1) do
    with {:ok, invitation, token} <- create(attrs) do
      deliver(invitation, url_fun.(token))
      {:ok, invitation}
    end
  end

  @doc """
  The unaccepted, unexpired invitation for `token`, with its app preloaded, or
  nil.
  """
  def get_by_token(token) when is_binary(token) do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false) do
      hashed = :crypto.hash(@hash_algorithm, decoded)
      cutoff = DateTime.add(DateTime.utc_now(), -@validity_in_days * 24 * 3600, :second)

      Repo.one(
        from i in Invitation,
          where: i.token == ^hashed and is_nil(i.accepted_at) and i.inserted_at > ^cutoff,
          preload: [:app]
      )
    else
      _ -> nil
    end
  end

  def get_by_token(_token), do: nil

  @doc """
  Accepts `invitation` for `user`: applies the role and marks it spent.

  Single-use — a second call finds nothing to accept and returns
  `{:error, :already_accepted}`. Returns `{:ok, user}`.
  """
  def accept(%Invitation{} = invitation, %User{} = user) do
    result =
      Repo.transact(fn ->
        with {:ok, claimed} <- claim(invitation, user),
             :ok <- apply_role(claimed, user) do
          {:ok, claimed}
        end
      end)

    # Emitted after the commit, not inside it: an audit handler writes to disk
    # and a webhook subscriber makes an HTTP call, neither of which belongs
    # under SQLite's single write lock.
    with {:ok, claimed} <- result do
      audit(claimed, "accept_invitation")
      {:ok, user}
    end
  end

  # Marks the invitation spent, but only if it still is. The guard is in the
  # WHERE clause rather than a read-then-write, so two clicks on the same link
  # cannot both apply a role.
  defp claim(invitation, user) do
    now = DateTime.utc_now(:second)

    query =
      from i in Invitation,
        where: i.id == ^invitation.id and is_nil(i.accepted_at),
        select: i

    case Repo.update_all(query, set: [accepted_at: now, accepted_by_id: user.id, updated_at: now]) do
      {1, [claimed]} -> {:ok, %{claimed | app: invitation.app}}
      {0, _} -> {:error, :already_accepted}
    end
  end

  defp apply_role(%Invitation{app: %App{} = app, role: role}, user)
       when is_binary(role) and role != "" do
    with {:ok, _assignment} <- You.Roles.set_role(app, user, role), do: :ok
  end

  defp apply_role(_invitation, _user), do: :ok

  @doc """
  Finds or creates the account an invitation is for.

  A new account is created confirmed and passwordless: the invitee proved the
  mailbox by opening the link, which is the same proof a magic-link login
  rests on, and they can set a password from their account page afterwards.
  """
  def resolve_user(%Invitation{email: email}) do
    case Accounts.get_user_by_email(email) do
      %User{} = user -> {:ok, user}
      nil -> register_invitee(email)
    end
  end

  defp register_invitee(email) do
    with {:ok, user} <- Accounts.register_user(%{email: email}) do
      user
      |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
      |> Repo.update()
    end
  end

  @doc "Pending invitations, newest first, with their apps preloaded."
  def list_pending do
    cutoff = DateTime.add(DateTime.utc_now(), -@validity_in_days * 24 * 3600, :second)

    Repo.all(
      from i in Invitation,
        where: is_nil(i.accepted_at) and i.inserted_at > ^cutoff,
        order_by: [desc: i.inserted_at],
        preload: [:app]
    )
  end

  @doc "Withdraws a pending invitation. Returns the number deleted (0 or 1)."
  def revoke(id) do
    query =
      from i in Invitation,
        where: i.id == ^id and is_nil(i.accepted_at),
        select: i

    case Repo.delete_all(query) do
      {1, [invitation]} ->
        invitation |> Repo.preload(:app) |> audit("revoke_invitation")
        1

      {count, _} ->
        count
    end
  end

  defp deliver(invitation, url) do
    app_name = (invitation.app && invitation.app.name) || instance_name()

    Accounts.deliver_invitation(invitation.email, %{
      email: invitation.email,
      url: url,
      app_name: app_name,
      role: invitation.role || "user",
      days: @validity_in_days
    })
  end

  defp instance_name do
    case Admin.list_apps() do
      [%App{name: name}] -> name
      _ -> "You"
    end
  end
end
