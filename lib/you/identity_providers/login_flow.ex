defmodule You.IdentityProviders.LoginFlow do
  @moduledoc """
  A single-use, short-lived record binding an in-flight federated login to the
  browser that started it.

  `/auth/:provider` mints an opaque `state` and a random `nonce`. `state`'s
  hash is what this record is looked up by; the `nonce`'s hash is stored
  alongside it, and the raw `nonce` is set as an HttpOnly cookie on the
  initiating browser. The callback can only complete when that same browser
  presents the cookie — comparing it against the stored hash is the CSRF
  defence RFC 9700 requires for the OIDC round trip, and is what today's
  session-based `state` check was doing before per-app hostnames made the
  session unavailable at the callback.

  `ctx` (the `callback_url`, `scopes`, `code_challenge` and
  `branding_app_slug` the flow started with) travels through this record
  rather than the session, so it survives the trip to an upstream IdP and
  back regardless of which host the callback lands on — ready for #121's
  cross-host handoff, and equivalent to today's session-carried values in
  the meantime.

  Modelled on `You.Accounts.UserToken`'s authorization-code pattern: hashed
  at rest, single-use (deleted the moment it is looked up), short expiry —
  rather than a second token pattern.
  """

  use Ecto.Schema
  import Ecto.Query

  alias You.IdentityProviders.LoginFlow

  @hash_algorithm :sha256
  @rand_size 32

  @doc "How long a flow record is valid for, in minutes."
  def validity_in_minutes, do: 10

  schema "federated_login_flows" do
    field :state_hash, :binary
    field :nonce_hash, :binary
    field :provider, :string
    field :ctx, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds a new flow record for `provider` carrying `ctx` (a string-keyed
  map). Returns `{state, nonce, flow}`: `state` is sent upstream to the IdP,
  `nonce` is set as the binding cookie, and neither is derivable from the
  other or from the unsaved `flow`.
  """
  def build(provider, ctx) when is_binary(provider) and is_map(ctx) do
    state = random_token()
    nonce = random_token()

    flow = %LoginFlow{
      state_hash: hash(state),
      nonce_hash: hash(nonce),
      provider: provider,
      ctx: Jason.encode!(ctx)
    }

    {state, nonce, flow}
  end

  @doc """
  Lookup query for an unexpired flow matching `state` and `provider`.

  Returns `{:ok, query}`, or `:error` when `state` is not validly encoded —
  which a tampered `state` is as likely as not to be.
  """
  def verify_query(state, provider) when is_binary(state) and is_binary(provider) do
    case decode(state) do
      {:ok, decoded} ->
        threshold = DateTime.add(DateTime.utc_now(), -validity_in_minutes() * 60, :second)

        query =
          from f in LoginFlow,
            where: f.state_hash == ^hash_decoded(decoded),
            where: f.provider == ^provider,
            where: f.inserted_at > ^threshold

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Whether `nonce` (the raw cookie value) matches the hash stored on `flow`,
  compared in constant time so the comparison itself leaks nothing.
  """
  def nonce_matches?(%LoginFlow{nonce_hash: nonce_hash}, nonce) when is_binary(nonce) do
    case decode(nonce) do
      {:ok, decoded} -> Plug.Crypto.secure_compare(hash_decoded(decoded), nonce_hash)
      :error -> false
    end
  end

  def nonce_matches?(%LoginFlow{}, _nonce), do: false

  @doc "The `ctx` map (string keys) stored on `flow`."
  def ctx(%LoginFlow{ctx: json}), do: Jason.decode!(json)

  defp random_token,
    do: @rand_size |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp decode(token), do: Base.url_decode64(token, padding: false)

  defp hash(token) do
    {:ok, decoded} = decode(token)
    hash_decoded(decoded)
  end

  defp hash_decoded(decoded), do: :crypto.hash(@hash_algorithm, decoded)
end
