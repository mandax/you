defmodule YouWeb.LoginBrandingPreviewTest do
  @moduledoc """
  `/users/log-in?app=<slug>` — an app's login page, openable for testing before
  the consuming app has a callback route to redirect from.

  Branding only. No callback URL is stashed, so signing in through it is an
  ordinary first-party login into You rather than an authorization-code flow.
  """
  use YouWeb.ConnCase, async: true

  alias You.Admin

  setup do
    {:ok, app, _secret} =
      Admin.create_app(%{
        slug: "branded",
        name: "Branded App",
        callback_url: "https://branded.example.com/cb",
        headline: "Sign in to Branded",
        subtitle: "by the makers of Branded",
        brand_color: "#7c3aed"
      })

    %{app: app}
  end

  test "renders the app's branding with no callback URL", %{conn: conn} do
    html = conn |> get(~p"/users/log-in?app=branded") |> html_response(200)

    assert html =~ "Sign in to Branded"
    assert html =~ "by the makers of Branded"
    assert html =~ "#7c3aed"
  end

  test "does not start an OAuth flow", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in?app=branded")

    assert get_session(conn, :callback_url) == nil
  end

  test "an unknown slug falls back to the plain page instead of erroring", %{conn: conn} do
    html = conn |> get(~p"/users/log-in?app=no-such-app") |> html_response(200)

    refute html =~ "Sign in to Branded"
  end

  test "the plain login page is still unbranded", %{conn: conn} do
    refute conn |> get(~p"/users/log-in") |> html_response(200) =~ "Sign in to Branded"
  end

  test "a later plain visit drops the preview branding", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in?app=branded")
    assert html_response(conn, 200) =~ "Sign in to Branded"

    refute conn |> get(~p"/users/log-in") |> html_response(200) =~ "Sign in to Branded"
  end
end
