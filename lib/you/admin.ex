defmodule You.Admin do
  @moduledoc """
  Admin operations: user management, app registration, settings.
  """

  import Ecto.Query, warn: false
  alias You.Repo
  alias You.Accounts.User
  alias You.Admin.App

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

  @doc """
  Registers a new app. Returns `{:ok, app}` or `{:error, changeset}`.
  """
  def create_app(attrs) do
    %App{}
    |> App.changeset(attrs)
    |> Repo.insert()
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
          {:ok, {user, _}} = You.Accounts.update_user_password(user, %{password: password})

          # Confirm the user so password login works without magic link
          {:ok, user} =
            user
            |> Ecto.Changeset.change(
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
  Finds the registered app whose callback URL matches the given URL as a prefix.
  Returns `{:ok, app}` or `:error`.
  """
  def lookup_app_by_callback(callback_url) when is_binary(callback_url) do
    case Enum.find(Repo.all(App), fn app ->
           String.starts_with?(callback_url, app.callback_url)
         end) do
      nil -> :error
      app -> {:ok, app}
    end
  end
end
