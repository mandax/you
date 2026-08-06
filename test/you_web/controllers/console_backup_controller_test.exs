defmodule YouWeb.ConsoleBackupControllerTest do
  @moduledoc """
  Downloading a sealed configuration bundle. LiveView cannot stream a file,
  so this is a plain controller action reached from the console's Backup
  section — admin-only, and every export is an audit event since it walks
  away with every secret the instance holds.
  """
  use YouWeb.ConnCase, async: false

  alias You.Admin
  alias You.Config.Vault
  alias You.Settings

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)
    %{conn: log_in_user(conn, user), admin: user}
  end

  test "an admin downloads a bundle sealed with the submitted password", %{conn: conn} do
    Settings.set(:jwt_expiry_hours, 6)

    conn = post(conn, ~p"/console/backup/export", %{"password" => "correct horse battery staple"})

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/octet-stream"
    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ ".you-bundle"
    assert disposition =~ Date.utc_today() |> Date.to_iso8601()

    assert {:ok, payload} = Vault.open(conn.resp_body, "correct horse battery staple")
    assert payload["settings"]["jwt_expiry_hours"] == 6
  end

  test "a missing password is rejected without downloading anything", %{conn: conn} do
    conn = post(conn, ~p"/console/backup/export", %{})

    assert redirected_to(conn) == ~p"/console/backup"
  end

  test "a password shorter than the minimum is rejected without downloading anything", %{
    conn: conn
  } do
    conn = post(conn, ~p"/console/backup/export", %{"password" => "short"})

    assert redirected_to(conn) == ~p"/console/backup"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "at least"
  end

  test "emits an admin audit event", %{conn: conn, admin: admin} do
    :telemetry.attach(
      "backup-export-test",
      [:you, :audit, :admin, :action],
      fn _event, _measure, metadata, pid -> send(pid, {:audit, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("backup-export-test") end)

    post(conn, ~p"/console/backup/export", %{"password" => "correct horse battery staple"})

    assert_receive {:audit, metadata}
    assert metadata.admin_user_id == admin.id
    assert metadata.action == "export_config_bundle"
  end

  test "a non-admin cannot export", %{conn: conn} do
    conn =
      conn
      |> log_in_user(You.AccountsFixtures.user_fixture())
      |> post(~p"/console/backup/export", %{"password" => "whatever"})

    assert html_response(conn, 404)
  end
end
