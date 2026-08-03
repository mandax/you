defmodule YouWeb.SettingsAuditTest do
  @moduledoc """
  Changing instance settings leaves a trail.

  The settings screen holds the management API token, the SCIM token, the
  Erlang cookie and the audit sink itself — an attacker who reaches it and is
  not recorded can repoint the trail and everything after is observed only by
  them.
  """
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.Admin

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)
    You.Settings.set(:onboarding_completed, true)

    :telemetry.attach(
      "settings-audit-test",
      [:you, :audit, :admin, :action],
      fn _event, _measure, meta, pid -> send(pid, {:audit, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("settings-audit-test") end)

    %{conn: log_in_user(conn, user)}
  end

  test "saving a changed setting records which key changed", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/console?view=settings")

    render_submit(lv, "save_settings", %{
      "audit_webhook_url" => "https://attacker.example/collect"
    })

    assert_received {:audit, %{action: "update_settings", target: target}}
    assert target =~ "audit_webhook_url"
  end

  test "the trail names keys, never their values", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/console?view=settings")

    render_submit(lv, "save_settings", %{"scim_bearer_token" => "super-secret-value"})

    assert_received {:audit, %{action: "update_settings", target: target}}
    assert target =~ "scim_bearer_token"
    refute target =~ "super-secret-value"
  end

  test "a save that changes nothing records nothing", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/console?view=settings")

    render_submit(lv, "save_settings", %{
      "session_expiry_hours" => to_string(You.Settings.get(:session_expiry_hours))
    })

    refute_received {:audit, %{action: "update_settings"}}
  end

  test "clearing a secret is recorded", %{conn: conn} do
    You.Settings.set(:scim_bearer_token, "something")
    {:ok, lv, _} = live(conn, ~p"/console?view=settings")

    render_click(lv, "clear_setting", %{"key" => "scim_bearer_token"})

    assert_received {:audit, %{action: "update_settings", target: "scim_bearer_token"}}
  end
end
