defmodule You.Webhooks do
  @moduledoc """
  Outbound webhook endpoints.

  Admins register endpoints (URL + subscribed events) in the console;
  `You.Webhooks.Dispatcher` delivers signed JSON payloads to every enabled
  endpoint subscribed to an event. Supersedes the single global
  `audit_webhook_url` setting, which keeps working independently.

  ## Security note (SSRF)

  Only the http/https schemes are accepted, but nothing prevents an
  endpoint from pointing at an internal address; deliveries originate
  from the server, so admins must only register endpoints they
  control.
  """

  import Ecto.Query, warn: false
  alias You.Repo
  alias You.Webhooks.Endpoint

  @telemetry_events [
    [:you, :audit, :login, :attempt],
    [:you, :audit, :login, :totp],
    [:you, :audit, :admin, :action],
    [:you, :audit, :token, :exchange],
    [:you, :audit, :token, :revoke],
    [:you, :audit, :token, :refresh],
    [:you, :audit, :account, :update],
    [:you, :audit, :consent, :grant],
    [:you, :audit, :consent, :revoke],
    [:you, :audit, :user, :registered],
    [:you, :audit, :user, :anonymized]
  ]

  # Lifecycle events join with "." (user.registered); the rest keep the
  # audit ":" convention (login:attempt).
  @dotted_events [[:user, :registered], [:user, :anonymized]]

  @doc """
  Returns the subscribable event names (e.g. `"login:attempt"`,
  `"user.registered"`), in declaration order.
  """
  def events, do: Enum.map(@telemetry_events, &event_type/1)

  @doc """
  Returns the telemetry events webhook deliveries attach to.
  """
  def telemetry_events, do: @telemetry_events

  @doc """
  Maps a telemetry event (`[:you, :audit, ...]`) to its public event
  type string.
  """
  def event_type(event_name) do
    suffix = Enum.drop(event_name, 2)

    if suffix in @dotted_events do
      Enum.join(suffix, ".")
    else
      Enum.join(suffix, ":")
    end
  end

  @doc """
  Generates a new webhook signing secret (base64url, 32 random bytes).
  """
  def generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc """
  Lists all webhook endpoints, newest first.
  """
  def list_endpoints do
    Repo.all(from e in Endpoint, order_by: [desc: e.inserted_at])
  end

  @doc """
  Gets a single endpoint, raising if not found.
  """
  def get_endpoint!(id), do: Repo.get!(Endpoint, id)

  @doc """
  Creates an endpoint. The secret is auto-generated when not given.

  Returns `{:ok, endpoint}` or `{:error, changeset}`.
  """
  def create_endpoint(attrs) do
    attrs = Map.put_new(attrs, "secret", generate_secret())

    result =
      %Endpoint{}
      |> Endpoint.changeset(attrs)
      |> Repo.insert()

    with {:ok, _} <- result, do: You.Webhooks.Dispatcher.reload()
    result
  end

  @doc """
  Updates an endpoint's url, events, or enabled flag.
  """
  def update_endpoint(%Endpoint{} = endpoint, attrs) do
    result =
      endpoint
      |> Endpoint.changeset(attrs)
      |> Repo.update()

    with {:ok, _} <- result, do: You.Webhooks.Dispatcher.reload()
    result
  end

  @doc """
  Rotates an endpoint's signing secret.

  Returns `{:ok, endpoint}` with the new plaintext secret in
  `endpoint.secret`; show it once, it is not displayed again.
  """
  def rotate_secret(%Endpoint{} = endpoint) do
    result =
      endpoint
      |> Ecto.Changeset.change(secret: generate_secret())
      |> Repo.update()

    with {:ok, _} <- result, do: You.Webhooks.Dispatcher.reload()
    result
  end

  @doc """
  Deletes an endpoint.
  """
  def delete_endpoint(%Endpoint{} = endpoint) do
    result = Repo.delete(endpoint)

    with {:ok, _} <- result, do: You.Webhooks.Dispatcher.reload()
    result
  end
end
