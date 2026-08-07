defmodule Mix.Tasks.You.AuditSlugsTest do
  @moduledoc """
  `mix you.audit_slugs` reports rows written before slug validation existed,
  so enabling the rule does not silently leave an app nobody can edit.
  """
  use You.DataCase, async: false

  alias You.Admin
  alias You.AdminFixtures

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  test "reports success when every existing slug satisfies the rule" do
    {:ok, _app, _secret} =
      Admin.create_app(%{
        slug: "clean-app",
        name: "Clean",
        callback_url: "https://clean.example.com/cb"
      })

    Mix.Tasks.You.AuditSlugs.run([])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "All app slugs satisfy"
  end

  test "reports offending apps, warns that renaming breaks consumers, and exits non-zero" do
    app = AdminFixtures.insert_legacy_app!("legacy.app")

    assert catch_exit(Mix.Tasks.You.AuditSlugs.run([])) == {:shutdown, 1}

    assert_received {:mix_shell, :error, [summary]}
    assert summary =~ "1 app(s)"

    assert_received {:mix_shell, :info, [listing]}
    assert listing =~ app.slug

    assert_received {:mix_shell, :info, [warning]}
    assert warning =~ "client_id"
    assert warning =~ "breaks every consumer"
    assert warning =~ "PATCH /api/v1/apps/:id"
  end

  # `new` was reserved after slug validation shipped (#130), so a row already
  # slugged `new` — written when that was still a legal slug — is exactly the
  # class of legacy row this task exists to surface: nothing about updating
  # its other fields would ever fail and point an operator at it.
  test "reports a legacy app slugged with a name reserved after it was created" do
    app = AdminFixtures.insert_legacy_app!("new")

    assert catch_exit(Mix.Tasks.You.AuditSlugs.run([])) == {:shutdown, 1}

    assert_received {:mix_shell, :error, [_summary]}

    assert_received {:mix_shell, :info, [listing]}
    assert listing =~ app.slug

    assert_received {:mix_shell, :info, [warning]}
    assert warning =~ "reserved"
    assert warning =~ "/console/apps/<slug>"
  end
end
