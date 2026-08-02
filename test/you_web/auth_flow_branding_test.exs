defmodule YouWeb.AuthFlowBrandingTest do
  @moduledoc """
  Every page of an authentication flow belongs to the app the flow started for:
  login, registration, password reset and the second factor all render bare and
  branded, and none of them shows You's own chrome.
  """
  use YouWeb.ConnCase, async: false

  alias You.Admin

  @chrome ["Get started", "Identity &amp; Access Management"]

  setup do
    {:ok, app, _secret} =
      Admin.create_app(%{
        slug: "branded",
        name: "Branded App",
        callback_url: "https://branded.example.com/cb",
        logo_url: "https://branded.example.com/logo.png",
        brand_color: "#7c3aed"
      })

    %{app: app}
  end

  defp assert_bare(html) do
    for chrome <- @chrome, do: refute(html =~ chrome)
    assert html =~ "https://branded.example.com/logo.png"
  end

  defp assert_chrome(html) do
    assert html =~ "Get started"
    refute html =~ "https://branded.example.com/logo.png"
  end

  describe "a flow started with ?app=" do
    test "the login page is bare", %{conn: conn} do
      assert_bare(conn |> get(~p"/users/log-in?app=branded") |> html_response(200))
    end

    test "registration keeps the app", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in?app=branded")

      assert_bare(conn |> get(~p"/users/register") |> html_response(200))
    end

    test "password reset keeps the app", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in?app=branded")

      assert_bare(conn |> get(~p"/users/reset-password") |> html_response(200))
    end

    test "registration can be entered directly with ?app=", %{conn: conn} do
      assert_bare(conn |> get(~p"/users/register?app=branded") |> html_response(200))
    end

    test "password reset can be entered directly with ?app=", %{conn: conn} do
      assert_bare(conn |> get(~p"/users/reset-password?app=branded") |> html_response(200))
    end
  end

  describe "a flow started from a callback URL" do
    test "registration keeps the app", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in?callback_url=https://branded.example.com/cb")

      assert_bare(conn |> get(~p"/users/register") |> html_response(200))
    end
  end

  describe "You's own flow" do
    test "the login page keeps the chrome", %{conn: conn} do
      assert_chrome(conn |> get(~p"/users/log-in") |> html_response(200))
    end

    test "registration keeps the chrome", %{conn: conn} do
      assert_chrome(conn |> get(~p"/users/register") |> html_response(200))
    end

    test "password reset keeps the chrome", %{conn: conn} do
      assert_chrome(conn |> get(~p"/users/reset-password") |> html_response(200))
    end
  end
end
