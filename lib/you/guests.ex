defmodule You.Guests do
  @moduledoc """
  Anonymous accounts and the path off them.

  A consumer app often wants state before signup — a cart, a draft, a game in
  progress — and then wants that state to survive the moment the person
  decides to create an account. Without this, the app either invents its own
  anonymous identity and has to merge it later, or asks for an email before it
  has earned one.

  A guest is an ordinary `users` row with `is_guest` set, a placeholder email
  nobody can receive mail at, and no password. Upgrading sets a real email and
  password on **the same row**: the user id a consumer app has already written
  into its own schema does not change, which is the whole point.

  ## What a guest cannot do

  There is no login for a guest. The token issued at creation is the only way
  back to that identity, so an app that loses it has lost the guest — that is
  the trade for not asking anyone to prove anything. A guest cannot be an
  admin, cannot hold a password or a second factor, and its placeholder
  address cannot receive a magic link or a reset.

  Off by default (`feature_guest_login`): it mints rows on an unauthenticated
  request, which is an operator's decision to make deliberately. Guests that
  are never upgraded are pruned by `delete_stale/1`.
  """

  import Ecto.Query, warn: false

  alias You.Accounts
  alias You.Accounts.User
  alias You.Repo

  @guest_email_domain "anonymous.you"

  @doc "The domain guest placeholder addresses use. Never receives mail."
  def email_domain, do: @guest_email_domain

  @doc "Whether this instance issues guest accounts."
  def enabled?, do: You.Settings.enabled?(:feature_guest_login)

  @doc """
  Creates a guest account. Returns `{:ok, user}` or
  `{:error, :guests_disabled}`.

  Confirmed on creation: there is no address to confirm, and leaving it
  unconfirmed would make a guest look like a stalled signup to every screen
  that counts them.
  """
  def create do
    if enabled?(), do: do_create(), else: {:error, :guests_disabled}
  end

  defp do_create do
    now = DateTime.utc_now(:second)

    %User{}
    |> Ecto.Changeset.change(
      email: unique_guest_email(),
      is_guest: true,
      confirmed_at: now
    )
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        :telemetry.execute([:you, :audit, :user, :registered], %{}, %{
          user_id: user.id,
          email: user.email,
          guest: true
        })

        {:ok, user}

      error ->
        error
    end
  end

  defp unique_guest_email do
    random = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    "guest-#{random}@#{@guest_email_domain}"
  end

  @doc """
  Whether `user` is a guest. Takes nil so callers need no guard of their own.
  """
  def guest?(%User{is_guest: true}), do: true
  def guest?(_user), do: false

  @doc """
  Turns a guest into a real account with `email` and `password`, keeping the
  same row — and so the same user id, roles and consents.

  Returns `{:ok, user}`, `{:error, :not_a_guest}` for an account that has
  already been upgraded (or never was one), or `{:error, changeset}`.

  Sessions are *not* invalidated. The guest and the account are the same
  person and the same row; signing them out of the app they were mid-flow in
  is exactly the data loss this feature exists to avoid.
  """
  def upgrade(%User{is_guest: true} = user, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    # Hashing and the pwned-password check happen before the write, as
    # everywhere else here: SQLite has a single writer.
    password_changeset = Accounts.prepare_password(attrs)

    Repo.transact(fn ->
      with {:ok, user} <- claim_email(user, attrs),
           {:ok, {user, _tokens}} <- apply_password(user, password_changeset) do
        :telemetry.execute([:you, :audit, :account, :update], %{}, %{
          user_id: user.id,
          email: user.email,
          action: "upgrade_guest"
        })

        {:ok, user}
      end
    end)
  end

  def upgrade(%User{}, _attrs), do: {:error, :not_a_guest}

  defp claim_email(user, attrs) do
    user
    |> User.email_changeset(attrs)
    |> Ecto.Changeset.put_change(:is_guest, false)
    |> Repo.update()
  end

  # A guest has no session tokens to expire on a password change — it never
  # had a password — but the shared helper deletes them all, which would end
  # the very session doing the upgrade. Write the hash directly instead.
  defp apply_password(_user, %Ecto.Changeset{valid?: false} = changeset) do
    {:error, %{changeset | action: :update}}
  end

  defp apply_password(user, changeset) do
    with {:ok, user} <-
           user
           |> Ecto.Changeset.change(Map.take(changeset.changes, [:hashed_password]))
           |> Repo.update() do
      {:ok, {user, []}}
    end
  end

  @doc """
  Deletes guest accounts older than `days` that were never upgraded.

  A guest nobody came back for is a row with no person behind it. Returns the
  number deleted.
  """
  def delete_stale(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 3600, :second)

    {count, _} =
      Repo.delete_all(from u in User, where: u.is_guest and u.inserted_at < ^cutoff)

    count
  end

  @doc "How many guest accounts exist."
  def count, do: Repo.aggregate(from(u in User, where: u.is_guest), :count)
end
