defmodule You.Audit.StreamerTest do
  use ExUnit.Case, async: false

  alias You.Audit.Streamer

  describe "build_payload/4" do
    test "builds a payload with the correct shape" do
      event = [:you, :audit, :login, :attempt]
      measurements = %{duration: 100}
      metadata = %{user_id: 1, result: :success}
      timestamp = ~U[2026-07-22 12:00:00Z]

      payload = Streamer.build_payload(event, measurements, metadata, timestamp)

      assert payload.event == "login:attempt"
      assert payload.measurements == %{duration: 100}
      assert payload.metadata == %{user_id: 1, result: :success}
      assert payload.at == "2026-07-22T12:00:00Z"
    end

    test "strips the [:you, :audit] prefix from the event name" do
      payload = Streamer.build_payload([:you, :audit, :token, :exchange], %{}, %{})
      assert payload.event == "token:exchange"
    end

    test "includes the timestamp by default" do
      payload = Streamer.build_payload([:you, :audit, :admin, :action], %{}, %{})

      assert payload.at != nil
      assert String.match?(payload.at, ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end

    test "handles empty measurements and metadata" do
      payload =
        Streamer.build_payload([:you, :audit, :login, :attempt], %{}, %{}, ~U[2026-01-01 00:00:00Z])

      assert payload.event == "login:attempt"
      assert payload.measurements == %{}
      assert payload.metadata == %{}
      assert payload.at == "2026-01-01T00:00:00Z"
    end
  end

  describe "recent/0" do
    test "returns [] instead of crashing when the streamer is unavailable" do
      # Stop the supervised streamer; the supervisor restarts it, but recent/0
      # must never raise in the interim — a stopped or freshly-restarted
      # streamer both yield an empty list.
      ref = Process.monitor(Process.whereis(Streamer))
      GenServer.stop(Streamer)
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert Streamer.recent() == []
    end
  end

  describe "when unconfigured" do
    setup do
      # Ensure the webhook URL is nil for these tests (default)
      original = Application.get_env(:you, :audit_webhook_url)
      Application.put_env(:you, :audit_webhook_url, nil)
      on_exit(fn -> Application.put_env(:you, :audit_webhook_url, original) end)
    end

    test "does not raise when an audit event fires" do
      :telemetry.execute(
        [:you, :audit, :login, :attempt],
        %{duration: 50},
        %{user_id: 1, email: "test@example.com", result: :success}
      )

      # Small pause so the fire-and-forget task can execute
      Process.sleep(10)

      # If we reach here without a crash, the no-op path works
      assert true
    end

    test "does not raise for any registered audit event" do
      events = [
        [:you, :audit, :login, :attempt],
        [:you, :audit, :login, :totp],
        [:you, :audit, :admin, :action],
        [:you, :audit, :token, :exchange],
        [:you, :audit, :token, :revoke],
        [:you, :audit, :token, :refresh],
        [:you, :audit, :account, :update],
        [:you, :audit, :consent, :grant],
        [:you, :audit, :consent, :revoke]
      ]

      for event <- events do
        :telemetry.execute(event, %{}, %{user_id: 1})
      end

      Process.sleep(10)

      assert true
    end
  end
end
