defmodule YouWeb.SessionGroupingTest do
  @moduledoc """
  The account page listed sessions flat, so "Session, signed in 2026-08-01"
  four times over was all a user had to go on when deciding whether to revoke
  one. Sessions now carry the sign-in they came from.
  """
  use YouWeb.ConnCase, async: false

  alias You.Accounts

  import You.AccountsFixtures

  setup do
    {:ok, app, _secret} =
      You.Admin.create_app(%{
        slug: "billing",
        name: "Meridian Billing",
        callback_url: "https://billing.example.com/cb"
      })

    %{app: app}
  end

  describe "recording" do
    test "a login through an app's flow names that app", %{conn: conn, app: app} do
      user = user_fixture() |> set_password()

      conn
      |> get(~p"/users/log-in", callback_url: app.callback_url)
      |> post(~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

      assert [session] = Accounts.list_user_sessions(user)
      assert session.app.slug == "billing"
    end

    test "a plain sign-in to You names no app", %{conn: conn} do
      user = user_fixture() |> set_password()

      post(conn, ~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

      assert [session] = Accounts.list_user_sessions(user)
      assert session.app == nil
    end

    test "an app deleted since the sign-in degrades to no app", %{conn: conn, app: app} do
      user = user_fixture() |> set_password()

      conn
      |> get(~p"/users/log-in", callback_url: app.callback_url)
      |> post(~p"/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

      {:ok, _app} = You.Admin.delete_app(app)

      assert [session] = Accounts.list_user_sessions(user)
      assert session.app == nil
    end
  end

  describe "grouping" do
    test "puts each app's sessions together, with You's own last", %{app: app} do
      user = user_fixture()

      Accounts.generate_user_session_token(user, app.slug)
      Accounts.generate_user_session_token(user, app.slug)
      Accounts.generate_user_session_token(user)

      groups = user |> Accounts.list_user_sessions() |> Accounts.group_user_sessions()

      assert [{%{slug: "billing"}, app_sessions}, {nil, own_sessions}] = groups
      assert length(app_sessions) == 2
      assert length(own_sessions) == 1
    end

    test "orders app groups by name" do
      user = user_fixture()

      for {slug, name} <- [{"zulu", "Zulu"}, {"alpha", "Alpha"}] do
        {:ok, _app, _secret} =
          You.Admin.create_app(%{
            slug: slug,
            name: name,
            callback_url: "https://#{slug}.example.com/cb"
          })

        Accounts.generate_user_session_token(user, slug)
      end

      groups = user |> Accounts.list_user_sessions() |> Accounts.group_user_sessions()

      assert [{%{name: "Alpha"}, _}, {%{name: "Zulu"}, _}] = groups
    end

    test "an empty list groups to nothing" do
      assert Accounts.group_user_sessions([]) == []
    end
  end

  describe "the account page" do
    setup :register_and_log_in_user

    test "names the app a session came from", %{conn: conn, user: user, app: app} do
      Accounts.generate_user_session_token(user, app.slug)

      html = conn |> get(~p"/users/settings") |> html_response(200)

      assert html =~ "Meridian Billing"
    end

    test "says what revoking actually ends", %{conn: conn} do
      html = conn |> get(~p"/users/settings") |> html_response(200)

      assert html =~ "one browser signed in to You"
    end
  end
end
