defmodule You.Webhooks.Endpoint do
  @moduledoc """
  An outbound webhook endpoint: a URL that receives signed JSON
  deliveries for a subscribed set of events.

  The `secret` is stored in plaintext — it is the shared key used to
  compute the `you-signature` HMAC on every delivery, so it cannot be
  hashed at rest. The console only displays it once, right after
  creation or rotation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "webhook_endpoints" do
    field :url, :string
    field :secret, :string
    field :events, {:array, :string}
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [:url, :secret, :events, :enabled])
    |> validate_required([:url, :secret, :events])
    |> validate_url()
    |> validate_events()
  end

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [url: "must be an http or https URL"]
      end
    end)
  end

  defp validate_events(changeset) do
    changeset
    |> validate_length(:events, min: 1)
    |> validate_subset(:events, You.Webhooks.events())
  end
end
