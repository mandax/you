defmodule You.IdentityProviders.Discovery do
  @moduledoc """
  Autofills a provider's endpoints from its issuer's
  `/.well-known/openid-configuration` document (OIDC discovery), so an admin
  only needs to supply the issuer URL for a provider with no preset.
  """

  @doc """
  Fetches and parses the discovery document for `issuer`. Returns
  `{:ok, attrs}` with `:issuer`, `:authorize_url`, `:token_url`,
  `:userinfo_url`, and `:scopes` (space-joined), or `{:error, reason}`.
  """
  def fetch(issuer) when is_binary(issuer) do
    case Req.get(discovery_url(issuer)) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, parse(body)}

      {:ok, %{status: status}} ->
        {:error, "discovery endpoint returned #{status}"}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discovery_url(issuer) do
    issuer
    |> String.trim_trailing("/")
    |> Kernel.<>("/.well-known/openid-configuration")
  end

  defp parse(body) do
    %{
      issuer: body["issuer"],
      authorize_url: body["authorization_endpoint"],
      token_url: body["token_endpoint"],
      userinfo_url: body["userinfo_endpoint"],
      scopes: parse_scopes(body["scopes_supported"])
    }
  end

  defp parse_scopes(scopes) when is_list(scopes), do: Enum.join(scopes, " ")
  defp parse_scopes(_), do: nil
end
