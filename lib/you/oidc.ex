defmodule You.OIDC do
  @moduledoc """
  OpenID Connect protocol layer on top of `You.JWT` and `You.Accounts`:
  id_token issuance, userinfo claims, token introspection, and client
  authentication for the OAuth endpoints.
  """

  alias You.Accounts
  alias You.Accounts.User
  alias You.Admin.App
  alias You.IAM.Claims
  alias You.JWT
  alias You.Repo

  @id_token_exp 3_600
  @userinfo_claims ["sub", "email", "name", "role"]

  @doc """
  Issues the full token-endpoint response for a user: access token, id_token,
  and a refresh token.

  `client_id` becomes the id_token audience; pass `nil` when the client did
  not identify itself and the id_token is issued without `aud`. Pass
  `refresh_token` to reuse one just issued by refresh-token rotation instead
  of creating another. `app_slug` binds per-app role claims to the app the
  auth code was issued for, falling back to `client_id`.
  """
  def issue_token_response(
        %User{} = user,
        scopes,
        client_id \\ nil,
        refresh_token \\ nil,
        app_slug \\ nil
      ) do
    app_slug = app_slug || client_id
    jwt_expiry = You.Settings.get(:jwt_expiry_hours) * 3600
    {:ok, access_token} = JWT.sign(Claims.build_scoped_claims(user, scopes, app_slug), jwt_expiry)
    {:ok, id_token} = id_token(user, scopes, app_slug)
    refresh_token = refresh_token || Accounts.create_refresh_token(user, scopes)

    %{
      access_token: access_token,
      token_type: "Bearer",
      expires_in: jwt_expiry,
      refresh_token: refresh_token,
      id_token: id_token
    }
  end

  @doc """
  Signs an OIDC id_token for the user: `iss` is the provider URL, `sub` the
  user id, `aud` the client, plus the scoped identity claims.
  """
  def id_token(%User{} = user, scopes, client_id) do
    claims =
      user
      |> Claims.build_scoped_claims(scopes)
      |> Map.put(:iss, YouWeb.Endpoint.url())
      |> maybe_put_aud(client_id)

    JWT.sign(claims, @id_token_exp)
  end

  @doc """
  Returns the userinfo claims for a valid access token, or
  `{:error, reason}` when the token is invalid, expired, or revoked.
  """
  def userinfo_claims(access_token) when is_binary(access_token) do
    with {:ok, claims} <- JWT.verify(access_token) do
      {:ok, Map.take(claims, @userinfo_claims)}
    end
  end

  @doc """
  RFC 7662 introspection: `active: true` plus the token claims for a valid
  token, `active: false` for anything else (invalid, expired, revoked).
  """
  def introspect(token) when is_binary(token) do
    case JWT.verify(token) do
      {:ok, claims} -> Map.merge(%{"active" => true}, claims)
      {:error, _reason} -> %{"active" => false}
    end
  end

  @doc """
  Authenticates a confidential client by slug + secret (constant-time SHA-256
  comparison, same scheme as `You.Admin.create_app/1`).

  Returns `{:ok, app}` or `{:error, :invalid_client}`.
  """
  def authenticate_client(client_id, client_secret)
      when is_binary(client_id) and is_binary(client_secret) do
    case Repo.get_by(App, slug: client_id) do
      %App{client_secret_hash: hash} = app when is_binary(hash) ->
        if :crypto.hash_equals(hash, :crypto.hash(:sha256, client_secret)) do
          {:ok, app}
        else
          {:error, :invalid_client}
        end

      _ ->
        # Hash anyway so unknown clients cost the same as wrong secrets.
        :crypto.hash(:sha256, client_secret)
        {:error, :invalid_client}
    end
  end

  def authenticate_client(_client_id, _client_secret), do: {:error, :invalid_client}

  defp maybe_put_aud(claims, nil), do: claims
  defp maybe_put_aud(claims, client_id), do: Map.put(claims, :aud, client_id)
end
