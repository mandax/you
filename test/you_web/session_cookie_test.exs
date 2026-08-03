defmodule YouWeb.SessionCookieTest do
  @moduledoc """
  The `secure` flag on the session cookie follows the scheme the instance is
  served on.

  It is not pinned on: a `secure` cookie is not sent over http at all, so
  hardcoding it would make `http://localhost` — the evaluation path — unable
  to hold a session. It is not pinned off either, or a production instance
  leaks its session cookie to any plaintext request that reaches the host
  before `force_ssl` redirects.
  """
  use YouWeb.ConnCase, async: false

  alias YouWeb.Endpoint

  setup do
    on_exit(fn ->
      Application.delete_env(:you, :secure_cookies)
      :persistent_term.erase({Endpoint, :session})
    end)
  end

  defp set_secure_cookies(value) do
    Application.put_env(:you, :secure_cookies, value)
    :persistent_term.erase({Endpoint, :session})
  end

  test "off by default, so localhost evaluation can hold a session" do
    set_secure_cookies(false)

    assert Keyword.fetch!(Endpoint.session_options(), :secure) == false
  end

  test "on when the instance is served over https" do
    set_secure_cookies(true)

    assert Keyword.fetch!(Endpoint.session_options(), :secure) == true
  end

  test "the flag reaches the cookie a browser is actually sent", %{conn: conn} do
    set_secure_cookies(true)

    conn = get(conn, ~p"/users/log-in")

    assert [cookie] = Plug.Conn.get_resp_header(conn, "set-cookie")
    assert cookie =~ "_you_key="
    assert cookie =~ "secure"
  end

  test "and is absent otherwise", %{conn: conn} do
    set_secure_cookies(false)

    conn = get(conn, ~p"/users/log-in")

    assert [cookie] = Plug.Conn.get_resp_header(conn, "set-cookie")
    refute cookie =~ "secure"
  end
end
