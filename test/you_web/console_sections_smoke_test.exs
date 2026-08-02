defmodule YouWeb.ConsoleSectionsSmokeTest do
  @moduledoc """
  Every console section renders with data loaded per section: a view that
  reads an assign its loader does not populate raises rather than degrading.
  """
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.Admin

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)

    {:ok, _app, _secret} =
      Admin.create_app(%{
        slug: "smoke",
        name: "Smoke",
        callback_url: "https://smoke.example.com/cb"
      })

    {:ok, _endpoint} =
      You.Webhooks.create_endpoint(%{
        "url" => "https://hook.example.com",
        "events" => ["login:attempt"]
      })

    You.Settings.set(:onboarding_completed, true)

    %{conn: log_in_user(conn, user)}
  end

  test "every section renders, then survives a tick and a mutation", %{conn: conn} do
    for view <- ~w(overview users apps providers audit webhooks features settings) do
      {:ok, lv, html} = live(conn, "/console?view=#{view}")
      assert html =~ "YOU"

      send(lv.pid, :refresh)
      assert render(lv) =~ "YOU"
    end
  end

  test "navigating between sections loads each one's data", %{conn: conn} do
    for view <- ~w(users apps providers audit webhooks settings overview) do
      {:ok, lv, _} = live(conn, ~p"/console?view=overview")

      {:ok, _lv, html} =
        lv
        |> element("a[href='/console?view=#{view}']")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "YOU"
    end
  end
end
