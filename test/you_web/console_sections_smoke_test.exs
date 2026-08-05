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
    for view <- ~w(overview users apps providers audit webhooks emails features settings backup) do
      {:ok, lv, html} = live(conn, "/console/#{view}")
      assert html =~ section_marker(view)

      send(lv.pid, :refresh)
      assert render(lv) =~ section_marker(view)
    end
  end

  # Every entry patches from the sidebar (see `YouWeb.Components.ConsoleChrome
  # .console_shell/1`), all of them `YouWeb.ConsoleLive`, so one connected
  # process carries the whole loop rather than a fresh `live/2` mount per
  # section.
  test "navigating between sections loads each one's data", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console")

    for view <- ~w(users apps providers audit webhooks emails settings backup overview) do
      html = lv |> element("nav a[href='/console/#{view}']") |> render_click()

      assert html =~ section_marker(view)
    end
  end

  # One distinctive phrase per section — each pulled from that section's own
  # `@section_copy` entry in `YouWeb.ConsoleLive` — so a section that renders
  # with *another* section's stale state (data left over from before a patch,
  # say) fails here instead of passing on the generic "YOU" wordmark every
  # page shares.
  defp section_marker("overview"), do: "Instance at a glance"
  defp section_marker("users"), do: "Filter by app, role, or status"
  defp section_marker("apps"), do: "delegate authentication to You"
  defp section_marker("providers"), do: "Upstream identity providers"
  defp section_marker("audit"), do: "Privileged actions, newest first"
  defp section_marker("webhooks"), do: "Signed outbound events"
  defp section_marker("emails"), do: "transactional mail You sends"
  defp section_marker("features"), do: "What this instance offers"
  defp section_marker("settings"), do: "Instance-wide tuning"
  defp section_marker("backup"), do: "Export an encrypted snapshot"
end
