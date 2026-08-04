defmodule YouWeb.ConsentRuleTest do
  @moduledoc """
  Consent is decided by the app, not by how the instance is deployed: a
  third-party app always asks, a first-party app never does, and flipping
  `YOU_MODE` changes neither.
  """
  use YouWeb.ConnCase, async: false

  alias You.Accounts
  alias You.Admin

  setup %{conn: conn} do
    {:ok, first_party, _} =
      Admin.create_app(%{
        slug: "ours",
        name: "Ours",
        callback_url: "https://ours.example.com/cb",
        first_party: true
      })

    {:ok, third_party, _} =
      Admin.create_app(%{
        slug: "theirs",
        name: "Theirs",
        callback_url: "https://theirs.example.com/cb"
      })

    user = You.AccountsFixtures.user_fixture()

    on_exit(fn -> Application.delete_env(:you, :single_app) end)

    %{conn: log_in_user(conn, user), first: first_party, third: third_party, user: user}
  end

  defp single_mode do
    You.Settings.set(:you_mode, "single")

    Application.put_env(:you, :single_app,
      slug: "ours",
      callback_url: "https://ours.example.com/cb"
    )
  end

  for mode <- [:multi, :single] do
    test "a first-party app skips consent in #{mode} mode", %{conn: conn, first: app} do
      if unquote(mode) == :single, do: single_mode()

      conn = get(conn, ~p"/users/log-in?callback_url=#{app.callback_url}")

      assert redirected_to(conn) =~ "#{app.callback_url}?code="
    end

    test "a third-party app still asks in #{mode} mode", %{conn: conn, third: app} do
      if unquote(mode) == :single, do: single_mode()

      html = conn |> get(~p"/users/log-in?callback_url=#{app.callback_url}") |> html_response(200)

      assert html =~ "Authorize"
      assert html =~ app.name
    end
  end

  test "the skip still records consent", %{conn: conn, first: app, user: user} do
    single_mode()
    get(conn, ~p"/users/log-in?callback_url=#{app.callback_url}")

    assert [consented] = Accounts.list_consented_apps(user)
    assert consented.id == app.id
  end
end
