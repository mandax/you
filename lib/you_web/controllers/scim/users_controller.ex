defmodule YouWeb.SCIM.UsersController do
  use YouWeb, :controller

  alias You.Accounts
  alias You.Accounts.User
  alias You.Repo
  alias You.SCIM.UserMapper

  @scim_error_schema "urn:ietf:params:scim:api:messages:2.0:Error"
  @scim_list_schema "urn:ietf:params:scim:schemas:core:2.0:ListResponse"

  @doc """
  GET /scim/v2/Users?filter=userName+eq+"value"

  Returns a SCIM ListResponse. Supports an optional `filter` query param
  for exact userName (email) matching.
  """
  def index(conn, params) do
    users =
      case parse_filter(params) do
        {:userName, value} ->
          case Accounts.get_user_by_email(value) do
            nil -> []
            user -> [user]
          end

        :none ->
          Repo.all(User)
      end

    list_response(conn, users)
  end

  @doc """
  GET /scim/v2/Users/:id

  Returns a single SCIM User resource or 404.
  """
  def show(conn, %{"id" => id}) do
    with {:ok, id} <- parse_id(id),
         %User{} = user <- Repo.get(User, id) do
      json(conn, UserMapper.to_scim(user))
    else
      :error -> scim_error(conn, 404, "User #{id} not found")
      nil -> scim_error(conn, 404, "User #{id} not found")
    end
  end

  @doc """
  POST /scim/v2/Users

  Creates a user from a SCIM User resource. The user is created as confirmed
  (no password). Returns 201 with a Location header.
  """
  def create(conn, params) do
    attrs = UserMapper.from_scim(params)

    case attrs[:email] do
      nil ->
        scim_error(conn, 400, "userName is required")

      email ->
        %User{}
        |> User.email_changeset(%{email: email, confirmed_at: DateTime.utc_now(:second)})
        |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
        |> Repo.insert()
        |> case do
          {:error, changeset} ->
            # Provisioning systems re-POST users they have already sent, and
            # SCIM says that is a 409, not a failure of the endpoint.
            scim_error(conn, conflict_status(changeset), changeset_detail(changeset))

          {:ok, user} ->
            :telemetry.execute([:you, :audit, :scim, :user, :create], %{}, %{
              user_id: user.id,
              email: user.email
            })

            create_response(conn, user)
        end
    end
  end

  defp create_response(conn, user) do
    conn
    |> put_status(201)
    |> put_resp_header("location", "/scim/v2/Users/#{user.id}")
    |> json(UserMapper.to_scim(user))
  end

  @doc """
  PUT /scim/v2/Users/:id

  Replaces a SCIM User resource. Supports updating userName → email
  and the `active` flag.
  """
  def update(conn, params) do
    do_update(conn, params, &UserMapper.from_scim/1)
  end

  @doc """
  PATCH /scim/v2/Users/:id

  Partially updates a SCIM User resource. Supports updating the `active` flag
  and userName → email.
  """
  def patch(conn, params) do
    do_update(conn, params, &UserMapper.from_scim_patch/1)
  end

  @doc """
  DELETE /scim/v2/Users/:id

  Deactivates the user (anonymizes personal data).
  Returns 204 No Content on success.
  """
  def delete(conn, %{"id" => id}) do
    with {:ok, id} <- parse_id(id),
         %User{} = user <- Repo.get(User, id) do
      Accounts.anonymize_user(user)

      :telemetry.execute([:you, :audit, :scim, :user, :delete], %{}, %{
        user_id: user.id
      })

      conn
      |> send_resp(204, "")
    else
      :error -> scim_error(conn, 404, "User #{id} not found")
      nil -> scim_error(conn, 404, "User #{id} not found")
    end
  end

  # -- Private helpers --

  defp do_update(conn, %{"id" => id} = params, mapper) do
    with {:ok, id} <- parse_id(id),
         %User{} = user <- Repo.get(User, id) do
      attrs = mapper.(params)

      renamed =
        if Map.has_key?(attrs, :email) and attrs.email != user.email do
          user |> User.email_changeset(%{email: attrs.email}) |> Repo.update()
        else
          {:ok, user}
        end

      case renamed do
        {:error, changeset} ->
          scim_error(conn, conflict_status(changeset), changeset_detail(changeset))

        {:ok, user} ->
          user = apply_active(user, Map.get(attrs, :active))
          json(conn, UserMapper.to_scim(user))
      end
    else
      :error -> scim_error(conn, 404, "User #{id} not found")
      nil -> scim_error(conn, 404, "User #{id} not found")
    end
  end

  defp apply_active(user, nil), do: user

  defp apply_active(user, true) do
    if user.confirmed_at do
      user
    else
      {:ok, updated} =
        user
        |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
        |> Repo.update()

      updated
    end
  end

  defp apply_active(user, false) do
    if user.confirmed_at do
      Accounts.delete_all_user_tokens(user)

      {:ok, updated} =
        user
        |> Ecto.Changeset.change(confirmed_at: nil)
        |> Repo.update()

      updated
    else
      user
    end
  end

  defp list_response(conn, users) do
    resources = Enum.map(users, &UserMapper.to_scim/1)

    json(conn, %{
      "schemas" => [@scim_list_schema],
      "totalResults" => length(resources),
      "itemsPerPage" => length(resources),
      "startIndex" => 1,
      "Resources" => resources
    })
  end

  # A taken userName is a conflict; anything else the changeset rejects is a
  # bad request.
  defp conflict_status(changeset) do
    if Keyword.has_key?(changeset.errors, :email), do: 409, else: 400
  end

  defp changeset_detail(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp scim_error(conn, status, detail) do
    conn
    |> put_status(status)
    |> json(%{
      "schemas" => [@scim_error_schema],
      "status" => "#{status}",
      "detail" => detail
    })
  end

  # Parses the SCIM filter query param.
  # Supports: filter=userName eq "value"
  defp parse_filter(%{"filter" => filter}) do
    case Regex.run(~r/^userName\s+eq\s+"([^"]*)"$/, filter) do
      [_, value] -> {:userName, value}
      nil -> :unsupported
    end
  end

  defp parse_filter(_params), do: :none

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error
end
