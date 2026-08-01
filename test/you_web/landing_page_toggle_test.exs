defmodule YouWeb.LandingPageToggleTest do
  @moduledoc """
  `/` when the instance has switched its public landing page off.

  An install that exists to serve one app is infrastructure, not a product
  with a homepage: the marketing page is the wrong first thing for both the
  operator and their users to land on.
  """
  use YouWeb.ConnCase, async: false

  alias You.Settings

  defp landing_off(_context) do
    Settings.set(:feature_landing_page, false)
    on_exit(fn -> Settings.set(:feature_landing_page, true) end)
    :ok
  end

  describe "landing page on (the default)" do
    test "/ serves the public page", %{conn: conn} do
      assert Settings.enabled?(:feature_landing_page)
      assert conn |> get(~p"/") |> html_response(200) =~ "Self-hosted identity"
    end

    test "the sitemap advertises it", %{conn: conn} do
      assert conn |> get(~p"/sitemap.xml") |> response(200) =~ "<loc>"
    end
  end

  describe "landing page off" do
    setup :landing_off

    test "an anonymous visitor gets the login page", %{conn: conn} do
      assert conn |> get(~p"/") |> redirected_to() == ~p"/users/log-in"
    end

    test "an admin gets the console", %{conn: conn} do
      user = You.AccountsFixtures.user_fixture()
      You.Admin.promote_admin!(user)

      assert conn |> log_in_user(user) |> get(~p"/") |> redirected_to() == ~p"/console"
    end

    test "a signed-in non-admin gets their account", %{conn: conn} do
      conn = log_in_user(conn, You.AccountsFixtures.user_fixture())

      assert conn |> get(~p"/") |> redirected_to() == ~p"/users/settings"
    end

    # Advertising a path that answers 302 spends crawl budget on a login form.
    test "the sitemap stops advertising it", %{conn: conn} do
      refute conn |> get(~p"/sitemap.xml") |> response(200) =~ "<loc>"
    end
  end
end
