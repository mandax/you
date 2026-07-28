defmodule You.IdentityProviders.GithubTest do
  use You.DataCase, async: false

  alias You.IdentityProviders.Github

  @access_token "gho_test-token"

  setup do
    original = Application.get_env(:you, :github_api_base_url)
    on_exit(fn -> Application.put_env(:you, :github_api_base_url, original) end)
    :ok
  end

  defp start_github_stub(port, user, emails) do
    test_pid = self()

    plug = fn conn, _opts ->
      auth_header = List.keyfind(conn.req_headers, "authorization", 0)
      send(test_pid, {:github_request, conn.request_path, auth_header})

      body =
        case conn.request_path do
          "/user" -> Jason.encode!(user)
          "/user/emails" -> Jason.encode!(emails)
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end

    server = start_supervised!({Bandit, plug: plug, port: port, ip: :loopback}, id: make_ref())
    on_exit(fn -> Process.unlink(server) end)
    Application.put_env(:you, :github_api_base_url, "http://localhost:#{port}")
  end

  describe "fetch_identity/1" do
    test "returns sub/email/email_verified shaped like OIDC userinfo, verified primary email" do
      start_github_stub(
        45_940,
        %{"id" => 42, "login" => "octocat"},
        [
          %{
            "email" => "octocat@users.noreply.github.com",
            "primary" => false,
            "verified" => true
          },
          %{"email" => "octocat@example.com", "primary" => true, "verified" => true}
        ]
      )

      assert {:ok, identity} = Github.fetch_identity(@access_token)
      assert_receive {:github_request, "/user", {"authorization", "Bearer " <> @access_token}}

      assert_receive {:github_request, "/user/emails",
                      {"authorization", "Bearer " <> @access_token}}

      assert identity["sub"] == "42"
      assert identity["email"] == "octocat@example.com"
      assert identity["email_verified"] == true
    end

    # The security case: the takeover check in
    # `Accounts.find_or_create_user_by_federated_identity/4` must see `false`
    # here, not GitHub's `/user` endpoint (whose own `email` field cannot be
    # trusted — it reports an address even when it is unverified).
    test "reports email_verified: false when the primary address is unverified" do
      start_github_stub(
        45_941,
        %{"id" => 7, "login" => "mallory"},
        [%{"email" => "mallory@example.com", "primary" => true, "verified" => false}]
      )

      assert {:ok, identity} = Github.fetch_identity(@access_token)
      assert identity["email"] == "mallory@example.com"
      assert identity["email_verified"] == false
    end

    test "picks the primary address out of several emails, ignoring non-primary ones' verified flag" do
      start_github_stub(
        45_942,
        %{"id" => 11, "login" => "multi-email"},
        [
          %{"email" => "old@example.com", "primary" => false, "verified" => false},
          %{"email" => "current@example.com", "primary" => true, "verified" => true},
          %{"email" => "unrelated@example.com", "primary" => false, "verified" => true}
        ]
      )

      assert {:ok, identity} = Github.fetch_identity(@access_token)
      assert identity["email"] == "current@example.com"
      assert identity["email_verified"] == true
    end

    test "errors when the account has no primary email" do
      start_github_stub(
        45_943,
        %{"id" => 9, "login" => "no-primary"},
        [%{"email" => "a@example.com", "primary" => false, "verified" => true}]
      )

      assert {:error, "GitHub account has no primary email"} =
               Github.fetch_identity(@access_token)
    end

    test "surfaces a non-200 response from /user as an error" do
      plug = fn conn, _opts -> Plug.Conn.send_resp(conn, 401, "bad credentials") end
      server = start_supervised!({Bandit, plug: plug, port: 45_944, ip: :loopback})
      on_exit(fn -> Process.unlink(server) end)
      Application.put_env(:you, :github_api_base_url, "http://localhost:45944")

      assert {:error, reason} = Github.fetch_identity(@access_token)
      assert reason =~ "401"
    end
  end
end
