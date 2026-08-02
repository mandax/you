defmodule You.WebhooksTest do
  use You.DataCase, async: false

  alias You.Webhooks
  alias You.Webhooks.Endpoint

  describe "create_endpoint/1" do
    test "generates a secret and persists subscriptions" do
      assert {:ok, %Endpoint{} = endpoint} =
               Webhooks.create_endpoint(%{
                 "url" => "https://hooks.example.com/you",
                 "events" => ["user.registered"]
               })

      assert byte_size(endpoint.secret) > 20
      assert endpoint.enabled
      assert endpoint.events == ["user.registered"]
    end

    test "rejects non-http URLs and unknown events" do
      assert {:error, changeset} =
               Webhooks.create_endpoint(%{"url" => "ftp://x", "events" => ["user.registered"]})

      assert "must be an http or https URL" in errors_on(changeset).url

      assert {:error, changeset} =
               Webhooks.create_endpoint(%{"url" => "https://x.example", "events" => ["nope"]})

      assert errors_on(changeset).events != []
    end
  end

  describe "rotate_secret/1" do
    test "changes the secret" do
      {:ok, endpoint} =
        Webhooks.create_endpoint(%{"url" => "https://a.example", "events" => ["user.registered"]})

      {:ok, rotated} = Webhooks.rotate_secret(endpoint)
      assert rotated.secret != endpoint.secret
    end
  end
end
