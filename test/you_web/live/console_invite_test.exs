defmodule YouWeb.ConsoleInviteTest do
  @moduledoc "Inviting someone to an app from its Members tab."
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.Invitations

  setup %{conn: conn} do
    admin = You.AccountsFixtures.user_fixture()
    You.Admin.promote_admin!(admin)

    {:ok, app, _secret} =
      You.Admin.create_app(%{
        slug: "billing",
        name: "Meridian Billing",
        callback_url: "https://billing.example.com/cb"
      })

    %{conn: log_in_user(conn, admin), app: app, admin: admin}
  end

  test "sends an invitation and lists it as pending", %{conn: conn, app: app, admin: admin} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.slug}?tab=members")

    # The role select is a custom component whose value is set by clicking, so
    # the role rides along as an extra submit param rather than a form field.
    html =
      lv
      |> form("#invite-member-form", %{"email" => "invitee@example.com"})
      |> render_submit(%{"role" => "admin"})

    assert html =~ "Invitation sent to invitee@example.com"
    assert html =~ "invitee@example.com"

    assert [invitation] = Invitations.list_pending()
    assert invitation.app_id == app.id
    assert invitation.role == "admin"
    assert invitation.invited_by_id == admin.id
  end

  test "refuses a role the app does not allow", %{conn: conn, app: app} do
    {:ok, _app} = You.Admin.update_app(app, %{"allowed_roles" => ["user"]})
    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.slug}?tab=members")

    html =
      lv
      |> form("#invite-member-form", %{"email" => "invitee@example.com"})
      |> render_submit(%{"role" => "admin"})

    assert html =~ "not allowed for this app"
    assert Invitations.list_pending() == []
  end

  test "withdraws a pending invitation", %{conn: conn, app: app} do
    {:ok, invitation, _token} =
      Invitations.create(%{email: "invitee@example.com", app_id: app.id, role: "user"})

    {:ok, lv, _html} = live(conn, ~p"/console/apps/#{app.slug}?tab=members")

    lv
    |> element("button[phx-click='revoke_invitation'][phx-value-id='#{invitation.id}']")
    |> render_click()

    assert Invitations.list_pending() == []
  end
end
