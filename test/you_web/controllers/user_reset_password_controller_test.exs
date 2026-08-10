defmodule YouWeb.UserResetPasswordControllerTest do
  use YouWeb.ConnCase, async: true

  import Ecto.Query
  import Swoosh.TestAssertions
  import You.AccountsFixtures

  alias You.Accounts
  alias You.Accounts.UserToken
  alias You.Repo

  @cb "https://app.example.com/cb"
  @evil "https://evil.example.com/cb"

  setup do
    %{user: user_fixture()}
  end

  # Drives the real entry points #140 describes: `new/2`'s query-param
  # stash, `create/2`'s propagation into the emailed link, and `edit/2`'s
  # re-stash from that link's own params — rather than seeding the session
  # directly, which would miss a regression in *where* callback_url is read
  # from.
  defp request_reset_and_open_link(conn, user, params) do
    # user_fixture/0 sends (and this process's mailbox still holds) its own
    # confirmation email; drain it so assert_email_sent below can't pick up
    # that stale message instead of the reset-password one this test cares
    # about.
    flush_mailbox()

    conn = get(conn, ~p"/users/reset-password", params)
    conn = post(conn, ~p"/users/reset-password", %{"user" => %{"email" => user.email}})

    assert_email_sent(fn email ->
      [url] = Regex.run(~r{https?://\S+}, email.text_body)
      uri = URI.parse(url)
      send(self(), {:reset_link, uri.path <> "?" <> (uri.query || "")})
      true
    end)

    assert_receive {:reset_link, path}
    get(conn, path)
  end

  defp code_param(url), do: URI.decode_query(URI.parse(url).query) |> Map.get("code")

  defp flush_mailbox do
    receive do
      {:email, _} -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  describe "the full reset flow, driven through the real query-param/email/link entry points" do
    test "an unregistered callback_url does not receive the code (no open redirect, no leaked code)",
         %{conn: conn, user: user} do
      conn = request_reset_and_open_link(conn, user, %{"callback_url" => @evil})

      [_, token] = String.split(conn.request_path, "/users/reset-password/")

      conn =
        put(conn, ~p"/users/reset-password/#{token}", %{
          "user" => %{
            "password" => valid_user_password(),
            "password_confirmation" => valid_user_password()
          }
        })

      # no external redirect to the attacker's host — at most an internal
      # redirect to You's own log-in page (which echoes callback_url as a
      # query param for the *next* login attempt, itself re-validated at
      # that flow's own completion; it is never followed here).
      refute String.starts_with?(redirected_to(conn), "http")
      assert redirected_to(conn) == "/users/log-in?callback_url=#{URI.encode_www_form(@evil)}"

      # the password did change...
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())

      # ...but no auth code was ever minted for the attacker's app, and the
      # session no longer carries the attacker's callback_url once the
      # response has been sent.
      assert Repo.aggregate(from(t in UserToken, where: t.context == "oauth_code"), :count) == 0
      refute get_session(conn, :callback_url)
    end

    test "a registered app's callback_url still receives the code end to end, with consent recorded",
         %{conn: conn, user: user} do
      {:ok, app, _secret} =
        You.Admin.create_app(%{slug: "app1", name: "App One", callback_url: @cb})

      conn = request_reset_and_open_link(conn, user, %{"callback_url" => @cb})

      [_, token] = String.split(conn.request_path, "/users/reset-password/")

      conn =
        put(conn, ~p"/users/reset-password/#{token}", %{
          "user" => %{
            "password" => valid_user_password(),
            "password_confirmation" => valid_user_password()
          }
        })

      loc = redirected_to(conn)
      assert String.starts_with?(loc, @cb <> "?")

      assert {:ok, resolved, ["email"], "app1"} =
               Accounts.consume_auth_code(code_param(loc), nil, client_authenticated: true)

      assert resolved.id == user.id
      assert {:ok, ["email"]} = Accounts.check_consent(user, app)
    end

    test "no callback_url anywhere in the flow falls back to the ordinary post-reset destination",
         %{conn: conn, user: user} do
      conn = request_reset_and_open_link(conn, user, %{})

      [_, token] = String.split(conn.request_path, "/users/reset-password/")

      conn =
        put(conn, ~p"/users/reset-password/#{token}", %{
          "user" => %{
            "password" => valid_user_password(),
            "password_confirmation" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/users/log-in"
    end
  end
end
