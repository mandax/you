defmodule You.Audit.HandlerTest do
  use ExUnit.Case, async: false

  alias You.Audit.Handler

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "you_audit_test_#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    {:ok, handler} = Handler.start_link(log_dir: tmp_dir)
    %{tmp_dir: tmp_dir, handler: handler}
  end

  test "writes a JSONL line for a login attempt event", %{tmp_dir: tmp_dir} do
    :telemetry.execute(
      [:you, :audit, :login, :attempt],
      %{},
      %{user_id: 1, email: "test@example.com", result: :success}
    )

    :timer.sleep(50)
    # The handler attaches to :telemetry globally, so concurrent tests may also
    # emit login:attempt events into this file — assert on our specific event
    # (user_id: 1) rather than the exact line count.
    events =
      Path.join(tmp_dir, "login.jsonl")
      |> File.read!()
      |> String.trim()
      |> String.split("\n")
      |> Enum.map(&Jason.decode!/1)

    event = Enum.find(events, &(&1["user_id"] == 1))
    assert event
    assert event["result"] == "success"
    assert event["event"] == "login:attempt"
  end

  test "persists user lifecycle events the streamer also listens for", %{tmp_dir: tmp_dir} do
    user_id = System.unique_integer([:positive])

    :telemetry.execute([:you, :audit, :user, :registered], %{}, %{user_id: user_id})

    :timer.sleep(50)

    events =
      Path.join(tmp_dir, "user.jsonl")
      |> File.read!()
      |> String.trim()
      |> String.split("\n")
      |> Enum.map(&Jason.decode!/1)

    event = Enum.find(events, &(&1["user_id"] == user_id))
    assert event
    assert event["event"] == "user.registered"
  end

  test "writes every event the webhook surface advertises", %{tmp_dir: tmp_dir} do
    for event_name <- You.Webhooks.telemetry_events() do
      :telemetry.execute(event_name, %{}, %{probe: You.Webhooks.event_type(event_name)})
    end

    :timer.sleep(50)

    written =
      tmp_dir
      |> File.ls!()
      |> Enum.flat_map(fn file ->
        tmp_dir |> Path.join(file) |> File.read!() |> String.trim() |> String.split("\n")
      end)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(& &1["probe"])
      |> MapSet.new()

    for event_name <- You.Webhooks.telemetry_events() do
      assert You.Webhooks.event_type(event_name) in written
    end
  end
end
