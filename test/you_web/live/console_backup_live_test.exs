defmodule YouWeb.ConsoleBackupLiveTest do
  @moduledoc """
  The console's Backup section: exporting flips `phx-trigger-action` so the
  browser posts the real download form; importing previews what a bundle
  would change before an explicit second action applies it.
  """
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.Admin
  alias You.Config.Bundle
  alias You.Config.Vault
  alias You.Settings

  @password "correct horse battery staple"

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)
    %{conn: log_in_user(conn, user), admin: user}
  end

  defp bundle_upload(lv, contents, name \\ "bundle.you-bundle") do
    file_input(lv, "form[phx-submit=preview_import]", :bundle, [
      %{name: name, content: contents, type: "application/octet-stream"}
    ])
  end

  test "submitting the export form flips the trigger and points at the download route", %{
    conn: conn
  } do
    {:ok, lv, html} = live(conn, "/console/backup")
    refute html =~ "phx-trigger-action"

    html =
      render_submit(form(lv, "#export-form"), %{
        "password" => @password,
        "password_confirmation" => @password
      })

    assert html =~ ~s(action="/console/backup/export")
    assert html =~ "phx-trigger-action"
  end

  test "a short export password is refused", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/console/backup")

    html =
      render_submit(form(lv, "#export-form"), %{
        "password" => "short",
        "password_confirmation" => "short"
      })

    assert html =~ "at least"
    refute html =~ "phx-trigger-action"
  end

  test "a mismatched confirmation is refused", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/console/backup")

    html =
      render_submit(form(lv, "#export-form"), %{
        "password" => @password,
        "password_confirmation" => "something else entirely"
      })

    assert html =~ "do not match"
    refute html =~ "phx-trigger-action"
  end

  test "previewing a bundle shows what actually changed, without changing anything", %{
    conn: conn
  } do
    {:ok, _app, _secret} =
      Admin.create_app(%{
        slug: "portable",
        name: "Portable",
        callback_url: "https://portable.example.com/cb"
      })

    sealed = Bundle.export() |> Vault.seal(@password)
    Settings.set(:jwt_expiry_hours, 9)

    {:ok, lv, _html} = live(conn, "/console/backup")

    upload = bundle_upload(lv, sealed)
    render_upload(upload, "bundle.you-bundle")

    html =
      render_submit(form(lv, "form[phx-submit=preview_import]"), %{"password" => @password})

    assert html =~ "Apply import"
    assert html =~ "jwt_expiry_hours"
    assert html =~ "portable"

    assert Settings.get(:jwt_expiry_hours) == 9
  end

  test "a bundle that changes privileged configuration is called out distinctly", %{conn: conn} do
    payload = %{
      "version" => 1,
      "settings" => %{"api_token" => "attacker-token"},
      "apps" => [
        %{
          "slug" => "evil-app",
          "name" => "Evil App",
          "callback_url" => "https://attacker.example.com/cb",
          "first_party" => true
        }
      ]
    }

    sealed = Vault.seal(payload, @password)

    {:ok, lv, _html} = live(conn, "/console/backup")

    upload = bundle_upload(lv, sealed)
    render_upload(upload, "bundle.you-bundle")

    html =
      render_submit(form(lv, "form[phx-submit=preview_import]"), %{"password" => @password})

    assert html =~ "privileged instance configuration"
    assert html =~ "Ignored"
    assert html =~ "api_token"
    assert html =~ "evil-app"
    assert html =~ "1st-party"

    refute You.Repo.get_by(You.Admin.App, slug: "evil-app")
  end

  test "a wrong password is reported without crashing, and can be retried", %{conn: conn} do
    sealed = Bundle.export() |> Vault.seal(@password)

    {:ok, lv, _html} = live(conn, "/console/backup")

    upload = bundle_upload(lv, sealed)
    render_upload(upload, "bundle.you-bundle")

    html = render_submit(form(lv, "form[phx-submit=preview_import]"), %{"password" => "nope"})
    assert html =~ "wrong password"
    refute html =~ "Apply import"

    html =
      render_submit(form(lv, "form[phx-submit=preview_import]"), %{"password" => @password})

    assert html =~ "Apply import"
  end

  test "a file that is not a bundle is reported as malformed", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/console/backup")

    upload = bundle_upload(lv, "not a bundle at all", "bundle.you-bundle")
    render_upload(upload, "bundle.you-bundle")

    html =
      render_submit(form(lv, "form[phx-submit=preview_import]"), %{"password" => @password})

    assert html =~ "not a bundle"
  end

  test "an unsupported version is reported distinctly", %{conn: conn} do
    sealed = Vault.seal(%{"version" => 999}, @password)

    {:ok, lv, _html} = live(conn, "/console/backup")

    upload = bundle_upload(lv, sealed)
    render_upload(upload, "bundle.you-bundle")

    html =
      render_submit(form(lv, "form[phx-submit=preview_import]"), %{"password" => @password})

    assert html =~ "newer version"
  end

  test "submitting the password without a file is a flash, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/console/backup")

    html =
      render_submit(form(lv, "form[phx-submit=preview_import]"), %{"password" => @password})

    assert html =~ "Choose a bundle file first"
  end

  test "applying an import upserts and emits an audit event", %{conn: conn, admin: admin} do
    :telemetry.attach(
      "backup-import-test",
      [:you, :audit, :admin, :action],
      fn _event, _measure, metadata, pid -> send(pid, {:audit, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("backup-import-test") end)

    Settings.set(:jwt_expiry_hours, 9)
    sealed = Bundle.export() |> Vault.seal(@password)
    Settings.set(:jwt_expiry_hours, 1)

    {:ok, lv, _html} = live(conn, "/console/backup")

    upload = bundle_upload(lv, sealed)
    render_upload(upload, "bundle.you-bundle")
    render_submit(form(lv, "form[phx-submit=preview_import]"), %{"password" => @password})

    render_click(lv, "apply_import")

    assert Settings.get(:jwt_expiry_hours) == 9
    assert_receive {:audit, metadata}
    assert metadata.admin_user_id == admin.id
    assert metadata.action == "import_config_bundle"
  end
end
