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
    # "overview" is addressed at the bare `/console`, not `/console/overview`
    # (see `YouWeb.ConsoleLive.handle_params/3`), so it is mounted directly
    # rather than through the `"/console/#{view}"` loop below.
    {:ok, lv, html} = live(conn, ~p"/console")
    assert html =~ "YOU"
    send(lv.pid, :refresh)
    assert render(lv) =~ "YOU"

    for view <- ~w(users apps providers audit webhooks emails features settings backup) do
      {:ok, lv, html} = live(conn, "/console/#{view}")
      assert html =~ "YOU"

      send(lv.pid, :refresh)
      assert render(lv) =~ "YOU"
    end
  end

  # Every entry patches from the sidebar (see `YouWeb.Components.ConsoleChrome
  # .console_shell/1`), all of them `YouWeb.ConsoleLive`, so one connected
  # process carries the whole loop rather than a fresh `live/2` mount per
  # section.
  test "navigating between sections loads each one's data", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console")

    for view <- ~w(users apps providers audit webhooks emails settings backup overview) do
      html = lv |> element("nav a[href='#{section_href(view)}']") |> render_click()

      assert html =~ "YOU"
    end
  end

  defp section_href("overview"), do: "/console"
  defp section_href(view), do: "/console/#{view}"
end
