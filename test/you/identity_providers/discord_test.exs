defmodule You.IdentityProviders.DiscordTest do
  use You.DataCase, async: false

  alias You.IdentityProviders.Discord

  @access_token "discord-test-token"

  setup do
    original = Application.get_env(:you, :discord_api_base_url)
    on_exit(fn -> Application.put_env(:you, :discord_api_base_url, original) end)
    :ok
  end

  defp start_stub(port, user) do
    plug = fn conn, _opts ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(user))
    end

    server = start_supervised!({Bandit, plug: plug, port: port, ip: :loopback}, id: make_ref())
    on_exit(fn -> Process.unlink(server) end)
    Application.put_env(:you, :discord_api_base_url, "http://localhost:#{port}")
  end

  test "maps /users/@me into an OIDC-shaped identity" do
    start_stub(45_980, %{"id" => "99", "email" => "d@example.com", "verified" => true})

    assert {:ok, identity} = Discord.fetch_identity(@access_token)
    assert identity["sub"] == "99"
    assert identity["email"] == "d@example.com"
    assert identity["email_verified"] == true
  end

  # An unverified address must not auto-link to an existing account, or anyone
  # could claim someone else's email by registering it and never confirming.
  test "reports an unverified email as unverified" do
    start_stub(45_981, %{"id" => "99", "email" => "d@example.com", "verified" => false})

    assert {:ok, %{"email_verified" => false}} = Discord.fetch_identity(@access_token)
  end

  test "refuses an account with no email" do
    start_stub(45_982, %{"id" => "99", "verified" => true})

    assert {:error, message} = Discord.fetch_identity(@access_token)
    assert message =~ "no email"
  end
end
