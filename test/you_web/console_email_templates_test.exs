defmodule YouWeb.ConsoleEmailTemplatesTest do
  @moduledoc """
  The Emails section: edit a template, and put it back to You's default.
  """
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.EmailTemplates

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    You.Admin.promote_admin!(user)
    You.Settings.set(:onboarding_completed, true)

    %{conn: log_in_user(conn, user)}
  end

  test "lists every template and marks the untouched ones as default", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/console/emails")

    for definition <- EmailTemplates.definitions() do
      assert html =~ definition.label
    end

    assert html =~ "default"
  end

  test "saving stores an override", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/emails")

    lv
    |> form("#email-template-magic_link", %{"subject" => "Meridian sign-in", "body" => "{{url}}"})
    |> render_submit()

    assert %{subject: "Meridian sign-in"} = EmailTemplates.get_override("magic_link")
  end

  test "a template missing its required placeholder is refused with a message", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/emails")

    html =
      lv
      |> form("#email-template-magic_link", %{"subject" => "Hi", "body" => "no link here"})
      |> render_submit()

    assert html =~ "{{url}}"
    assert EmailTemplates.get_override("magic_link") == nil
  end

  test "resetting drops the override", %{conn: conn} do
    {:ok, _} = EmailTemplates.upsert("magic_link", %{"subject" => "Custom", "body" => "{{url}}"})

    {:ok, lv, _html} = live(conn, ~p"/console/emails")

    lv
    |> element("button[phx-click='reset_email_template'][phx-value-key='magic_link']")
    |> render_click()

    assert EmailTemplates.get_override("magic_link") == nil
  end
end
