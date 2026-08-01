defmodule YouWeb.MailboxAccessTest do
  @moduledoc """
  Who can reach `/console/mailbox`.

  The fallback mailbox holds magic links and email 2FA codes — bearer
  credentials, not diagnostics. Anyone who can read it can sign in as anyone
  who has been sent mail, so the gate matters more than the feature.
  """
  use YouWeb.ConnCase, async: false

  alias You.Admin

  defp local_mail(_context) do
    Application.put_env(:you, :mail_transport, :local)
    on_exit(fn -> Application.delete_env(:you, :mail_transport) end)
    :ok
  end

  defp admin(%{conn: conn}) do
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)
    %{conn: log_in_user(conn, user), admin: user}
  end

  describe "access control" do
    setup :local_mail

    test "an anonymous visitor is sent to the login page", %{conn: conn} do
      conn = get(conn, ~p"/console/mailbox")

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "a signed-in non-admin gets nothing", %{conn: conn} do
      conn =
        conn
        |> log_in_user(You.AccountsFixtures.user_fixture())
        |> get(~p"/console/mailbox")

      assert html_response(conn, 404)
    end

    test "an admin can read it while mail is unconfigured", %{conn: conn} do
      %{conn: conn} = admin(%{conn: conn})

      assert conn |> get(~p"/console/mailbox") |> html_response(200)
    end
  end

  describe "transport gate" do
    setup [:admin]

    test "an admin is turned away when mail goes out over SMTP", %{conn: conn} do
      Application.put_env(:you, :mail_transport, :smtp)
      on_exit(fn -> Application.delete_env(:you, :mail_transport) end)

      conn = get(conn, ~p"/console/mailbox")

      assert redirected_to(conn) == "/console"
    end
  end
end
