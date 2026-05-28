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
    lines = File.read!(Path.join(tmp_dir, "login.jsonl")) |> String.trim() |> String.split("\n")
    assert length(lines) == 1

    event = Jason.decode!(hd(lines))
    assert event["user_id"] == 1
    assert event["result"] == "success"
    assert event["event"] == "login:attempt"
  end
end
