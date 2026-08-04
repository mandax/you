defmodule YouWeb.PanelBrandingTest do
  @moduledoc """
  In single-app mode the signed-in account area is that app's user management,
  so it wears the app's mark and colour. The console never does: it administers
  the instance, not an app.
  """
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.Admin

  setup %{conn: conn} do
    {:ok, app, _secret} =
      Admin.create_app(%{
        slug: "solo",
        name: "Solo App",
        callback_url: "https://solo.example.com/cb",
        logo_url: "https://solo.example.com/logo.png",
        brand_color: "#7c3aed"
      })

    user = You.AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), app: app, user: user}
  end

  defp single_mode(_context) do
    You.Settings.set(:you_mode, "single")

    Application.put_env(:you, :single_app,
      slug: "solo",
      callback_url: "https://solo.example.com/cb"
    )

    on_exit(fn -> Application.delete_env(:you, :single_app) end)

    :ok
  end

  describe "single-app mode" do
    setup :single_mode

    test "account settings wear the app's logo and colour", %{conn: conn} do
      html = conn |> get(~p"/users/settings") |> html_response(200)

      assert html =~ "https://solo.example.com/logo.png"
      assert html =~ "app-branded"
      assert html =~ "#7c3aed"
    end

    test "passkeys page too", %{conn: conn} do
      html = conn |> get(~p"/users/settings/passkeys") |> html_response(200)

      assert html =~ "https://solo.example.com/logo.png"
    end

    test "the console stays You's own", %{conn: conn, user: user} do
      Admin.promote_admin!(user)
      {:ok, _lv, html} = live(conn, ~p"/console")

      refute html =~ "https://solo.example.com/logo.png"
      refute html =~ "app-branded"
    end
  end

  describe "multi-app mode" do
    test "the account area stays You's own", %{conn: conn} do
      html = conn |> get(~p"/users/settings") |> html_response(200)

      refute html =~ "https://solo.example.com/logo.png"
      refute html =~ "app-branded"
    end
  end
end
