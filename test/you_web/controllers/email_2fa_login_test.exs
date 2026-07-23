defmodule YouWeb.Email2faLoginTest do
  use YouWeb.ConnCase, async: false

  import You.AccountsFixtures
  alias You.Accounts

  defp code_from_email do
    receive do
      {:email, email} ->
        case Regex.run(~r/code is:\s*(\d{6})/, email.text_body || "") do
          [_, code] -> code
          _ -> code_from_email()
        end
    after
      300 -> flunk("no email 2FA code was delivered")
    end
  end

  setup do
    user = user_fixture() |> set_password()
    {:ok, _} = Accounts.enable_email_2fa(user)
    %{user: user}
  end

  test "password login with email 2FA requires the emailed code", %{conn: conn, user: user} do
    conn =
      post(conn, ~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    assert redirected_to(conn) == ~p"/users/log-in/email-2fa"
    refute get_session(conn, :user_token)

    code = code_from_email()
    conn = post(conn, ~p"/users/log-in/email-2fa", %{"email_2fa" => %{"code" => code}})

    assert get_session(conn, :user_token)
    assert redirected_to(conn) == ~p"/users/dashboard"
  end

  test "a wrong code re-renders the form and does not log in", %{conn: conn, user: user} do
    conn =
      post(conn, ~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    _ = code_from_email()
    conn = post(conn, ~p"/users/log-in/email-2fa", %{"email_2fa" => %{"code" => "000000"}})

    assert html_response(conn, 200) =~ "Invalid or expired code"
    refute get_session(conn, :user_token)
  end
end
