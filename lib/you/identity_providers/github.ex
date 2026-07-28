defmodule You.IdentityProviders.Github do
  @moduledoc """
  GitHub OAuth adapter.

  GitHub is not OIDC: there is no `sub` claim and no standard userinfo
  endpoint. Identity comes from `GET /user` — its numeric `id` stands in for
  `sub` — and the verified-email flag comes from `GET /user/emails`, not from
  `/user` itself. `/user`'s `email` field can be null (the user has hidden it)
  or present-but-unverified, so it cannot be trusted on its own for the
  takeover check that guards
  `You.Accounts.find_or_create_user_by_federated_identity/4`.
  """

  @default_base_url "https://api.github.com"

  @doc """
  Fetches the authenticated GitHub identity for `access_token`.

  Returns `{:ok, userinfo}` shaped like an OIDC userinfo response —
  `"sub"` (the stringified GitHub user id), `"email"`, and `"email_verified"`
  (boolean, taken from the *primary* address in `/user/emails`) — so callers
  can treat it the same way as a standard OIDC userinfo map. Returns
  `{:error, reason}` on any upstream failure or if the account has no primary
  email.
  """
  def fetch_identity(access_token) when is_binary(access_token) do
    with {:ok, user} <- get_json(base_url() <> "/user", access_token),
         {:ok, emails} <- get_json(base_url() <> "/user/emails", access_token),
         {:ok, primary} <- primary_email(emails) do
      {:ok,
       %{
         "sub" => to_string(user["id"]),
         "email" => primary["email"],
         "email_verified" => primary["verified"] == true
       }}
    end
  end

  defp primary_email(emails) when is_list(emails) do
    case Enum.find(emails, & &1["primary"]) do
      nil -> {:error, "GitHub account has no primary email"}
      email -> {:ok, email}
    end
  end

  defp primary_email(_emails), do: {:error, "unexpected response from /user/emails"}

  # Overridable so tests can point this at a local stub instead of the real
  # `api.github.com` — GitHub has no per-tenant base URL, so there is nothing
  # else to parameterize this on.
  defp base_url, do: Application.get_env(:you, :github_api_base_url, @default_base_url)

  defp get_json(url, access_token) do
    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "you-identity-provider"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "GitHub API returned #{status} for #{url}"}
      {:error, %{reason: reason}} -> {:error, reason}
    end
  end
end
