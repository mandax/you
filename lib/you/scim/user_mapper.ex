defmodule You.SCIM.UserMapper do
  @moduledoc """
  Maps between a `You.Accounts.User` and the SCIM 2.0 User resource
  representation (RFC 7644 §4.1).
  """

  alias You.Accounts.User

  @scim_schema "urn:ietf:params:scim:schemas:core:2.0:User"

  @doc """
  Converts a `%User{}` into a SCIM User resource map ready for JSON encoding.
  """
  def to_scim(%User{} = user) do
    %{
      "schemas" => [@scim_schema],
      "id" => user.id,
      "userName" => user.email,
      "emails" => [
        %{"value" => user.email, "primary" => true}
      ],
      "active" => user.confirmed_at != nil,
      "meta" => %{
        "resourceType" => "User",
        "created" => user.inserted_at,
        "lastModified" => user.updated_at || user.inserted_at,
        "location" => "/scim/v2/Users/#{user.id}",
        "version" => to_w3c_datetime(user.updated_at || user.inserted_at)
      }
    }
  end

  @doc """
  Converts a SCIM User resource body into an Ecto attrs map suitable for
  `User.email_changeset/2` plus the `active` flag.

  Only the fields we support are extracted: `userName` → `:email`,
  `active` → `:active` (boolean, stored as `confirmed_at` by the controller).
  """
  def from_scim(params) when is_map(params) do
    attrs = %{}

    attrs =
      case Map.get(params, "userName") do
        nil -> attrs
        val when is_binary(val) -> Map.put(attrs, :email, val)
      end

    attrs =
      case Map.get(params, "active") do
        nil -> attrs
        val when is_boolean(val) -> Map.put(attrs, :active, val)
      end

    attrs
  end

  @doc """
  Same as `from_scim/1` but for PATCH-style partial updates — keeps only the
  keys present in the request body.
  """
  def from_scim_patch(params) when is_map(params) do
    params
    |> from_scim()
    |> Map.take([:email, :active])
  end

  # W3C datetime format: yyyy-MM-dd'T'HH:mm:ss.SSS'Z' (always UTC).
  defp to_w3c_datetime(dt) do
    dt
    |> DateTime.truncate(:millisecond)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%3fZ")
  end
end
