defmodule You.Webhooks.DispatcherTest do
  use You.DataCase, async: false

  alias You.Webhooks

  @port 45_917

  setup do
    test_pid = self()
    failures = :counters.new(1, [])

    plug = fn conn, _opts ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:webhook_delivery, conn.req_headers, body})

      # Fail the first `failures` deliveries, then succeed.
      status =
        if :counters.get(failures, 1) == 0 do
          200
        else
          :counters.sub(failures, 1, 1)
          500
        end

      Plug.Conn.send_resp(conn, status, "")
    end

    server = start_supervised!({Bandit, plug: plug, port: @port, ip: :loopback})
    on_exit(fn -> Process.unlink(server) end)

    %{failures: failures, url: "http://localhost:#{@port}/hook"}
  end

  defp create_endpoint(url, events) do
    {:ok, endpoint} = Webhooks.create_endpoint(%{"url" => url, "events" => events})
    endpoint
  end

  defp emit_user_registered do
    :telemetry.execute([:you, :audit, :user, :registered], %{}, %{
      user_id: 1,
      email: "hooked@example.com"
    })
  end

  test "delivers a signed payload to subscribed endpoints", %{url: url} do
    endpoint = create_endpoint(url, ["user.registered"])

    emit_user_registered()

    assert_receive {:webhook_delivery, headers, body}, 2_000

    payload = Jason.decode!(body)
    assert payload["type"] == "user.registered"
    assert payload["data"]["email"] == "hooked@example.com"

    {"you-signature", signature_header} = List.keyfind(headers, "you-signature", 0)
    ["t=" <> t, "v1=" <> v1] = String.split(signature_header, ",")

    expected =
      :hmac
      |> :crypto.mac(:sha256, endpoint.secret, "#{t}.#{body}")
      |> Base.encode16(case: :lower)

    assert v1 == expected
  end

  test "does not deliver to unsubscribed or disabled endpoints", %{url: url} do
    create_endpoint(url, ["login:attempt"])

    disabled = create_endpoint(url, ["user.registered"])
    {:ok, _} = Webhooks.update_endpoint(disabled, %{"enabled" => false})

    emit_user_registered()

    refute_receive {:webhook_delivery, _, _}, 300
  end

  test "retries on 5xx and succeeds", %{url: url, failures: failures} do
    :counters.add(failures, 1, 2)
    create_endpoint(url, ["user.registered"])

    emit_user_registered()

    assert_receive {:webhook_delivery, _, _}, 2_000
    assert_receive {:webhook_delivery, _, _}, 6_000
    assert_receive {:webhook_delivery, _, _}, 15_000
    assert :counters.get(failures, 1) == 0
  end

  test "Accounts.register_user emits a user.registered delivery", %{url: url} do
    create_endpoint(url, ["user.registered"])

    {:ok, _user} = You.Accounts.register_user(%{email: "registered-via-api@example.com"})

    assert_receive {:webhook_delivery, _, body}, 2_000
    assert Jason.decode!(body)["data"]["email"] == "registered-via-api@example.com"
  end
end
