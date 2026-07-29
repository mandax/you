defmodule You.IdentityProviders.Discord do
  @moduledoc """
  Discord identity lookup.

  Discord is not an OIDC provider: there is no `sub` claim and no standard
  userinfo endpoint, only `/users/@me`. This maps that response into the same
  shape the OIDC path produces, so callers treat both alike.

  `verified` on the Discord account is what gates linking. An unverified
  address must not auto-link to an existing You account, or anyone could claim
  someone else's email by registering it on Discord and never confirming it.
  """

  @default_base_url "https://discord.com/api/v10"

  @doc """
  Exchanges an access token for `%{"sub", "email", "email_verified"}`.

  Returns `{:error, reason}` on any upstream failure, or when the account has
  no email address at all — Discord permits that, and You cannot create an
  account without one.
  """
  def fetch_identity(access_token) when is_binary(access_token) do
    with {:ok, user} <- get_json(base_url() <> "/users/@me", access_token),
         {:ok, email} <- email_of(user) do
      {:ok,
       %{
         "sub" => to_string(user["id"]),
         "email" => email,
         "email_verified" => user["verified"] == true
       }}
    end
  end

  defp email_of(%{"email" => email}) when is_binary(email) and email != "", do: {:ok, email}
  defp email_of(_user), do: {:error, "Discord account has no email address"}

  # Overridable so tests can point this at a local stub rather than the real
  # API. Discord has no per-tenant base URL, so there is nothing else to
  # parameterize this on.
  defp base_url, do: Application.get_env(:you, :discord_api_base_url, @default_base_url)

  defp get_json(url, access_token) do
    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"accept", "application/json"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "Discord API returned #{status}"}
      {:error, %{reason: reason}} -> {:error, reason}
    end
  end
end
