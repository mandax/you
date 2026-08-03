defmodule You.HostileBundleTest do
  @moduledoc """
  The bundle a security review described: one an attacker hands an admin,
  hoping the preview looks like a routine restore. Every hostile change it
  carries must be visible before the admin applies it, and the keys that
  authenticate this instance must not be applicable at all.
  """
  use You.DataCase, async: false

  setup do
    on_exit(fn ->
      You.Settings.set(:audit_webhook_url, "")
      You.Audit.Streamer.reload()
    end)
  end

  alias You.Config.Bundle

  defp hostile_payload do
    %{
      "version" => 1,
      "settings" => %{
        "api_token" => "attacker-owned",
        "scim_bearer_token" => "attacker-owned",
        "erlang_cookie" => "attacker-owned",
        "audit_webhook_url" => "https://attacker.example/collect",
        "smtp_host" => "mx.attacker.example"
      },
      "apps" => [
        %{
          "slug" => "evil",
          "name" => "Evil",
          "callback_url" => "https://attacker.example/cb",
          "first_party" => true
        }
      ],
      "identity_providers" => [
        %{
          "slug" => "evil-idp",
          "display_name" => "Sign in with Evil",
          "kind" => "oidc",
          "client_id" => "x",
          "authorize_url" => "https://attacker.example/authorize",
          "token_url" => "https://attacker.example/token",
          "enabled" => true
        }
      ],
      "webhook_endpoints" => [
        %{"url" => "https://attacker.example/hook", "events" => ["login:attempt"]}
      ]
    }
  end

  test "the preview flags the bundle as privileged" do
    assert {:ok, diff} = Bundle.preview(hostile_payload())
    assert diff.privileged?
  end

  test "the attacker's destinations are visible, not just counted" do
    {:ok, diff} = Bundle.preview(hostile_payload())
    rendered = inspect(diff)

    assert rendered =~ "https://attacker.example/collect"
    assert rendered =~ "mx.attacker.example"
    assert rendered =~ "https://attacker.example/cb"
    assert rendered =~ "https://attacker.example/authorize"
    assert rendered =~ "https://attacker.example/hook"
  end

  test "instance identity is reported as ignored, not silently dropped" do
    {:ok, diff} = Bundle.preview(hostile_payload())
    ignored = Enum.sort(diff.ignored_settings)

    assert ignored == ["api_token", "erlang_cookie", "scim_bearer_token"]
  end

  test "importing does not apply instance identity" do
    before_token = You.Settings.get(:api_token)
    before_cookie = You.Settings.get(:erlang_cookie)

    assert {:ok, _summary} = Bundle.import(hostile_payload())

    assert You.Settings.get(:api_token) == before_token
    assert You.Settings.get(:erlang_cookie) == before_cookie
    assert You.Settings.get(:scim_bearer_token) != "attacker-owned"
  end

  test "secret values are never rendered into the preview" do
    payload = put_in(hostile_payload(), ["settings", "smtp_password"], "hunter2-plaintext")

    {:ok, diff} = Bundle.preview(payload)

    refute inspect(diff) =~ "hunter2-plaintext"
  end

  describe "malformed payloads" do
    test "return an error instead of raising" do
      for bad <- [
            %{"version" => 1, "settings" => []},
            %{"version" => 1, "apps" => %{}},
            %{"version" => 1, "settings" => %{"smtp_port" => "not-a-number"}},
            %{"version" => 1, "settings" => %{"jwt_expiry_hours" => 1.5}},
            %{"version" => 99}
          ] do
        assert {:error, _} = Bundle.preview(bad)
        assert {:error, _} = Bundle.import(bad)
      end
    end
  end
end
