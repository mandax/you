defmodule Mix.Tasks.You.AuditHostnameLabelsTest do
  @moduledoc """
  `mix you.audit_hostname_labels` reports a `hostname_label` that has
  *become* a collision with the canonical host — accepted at write time
  under a different (or no) `APP_HOSTNAME_TEMPLATE`, and never re-checked
  since. The write-time guard (`App.changeset/2`) cannot catch this, so this
  task is the only thing that can, mirroring `mix you.audit_slugs` (#119).
  """
  use You.DataCase, async: false

  alias You.Admin
  alias You.AdminFixtures

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp enable_hostnames!(template) do
    Application.put_env(:you, :app_hostname_template, template)
    on_exit(fn -> Application.delete_env(:you, :app_hostname_template) end)
  end

  test "reports success when no template is configured, since nothing can collide" do
    AdminFixtures.insert_legacy_app!("whatever")
    |> Ecto.Changeset.change(hostname_label: "anything")
    |> You.Repo.update!()

    Mix.Tasks.You.AuditHostnameLabels.run([])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "No app hostname_label collides"
  end

  test "reports success when every label is clean under the configured template" do
    enable_hostnames!("{label}.example.com")

    {:ok, _app, _secret} =
      Admin.create_app(%{
        slug: "clean-app",
        name: "Clean",
        callback_url: "https://clean.example.com/cb",
        hostname_label: "clean"
      })

    Mix.Tasks.You.AuditHostnameLabels.run([])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "No app hostname_label collides"
  end

  test "reports a label that collides, written before the template existed" do
    # No template configured yet, so this write-time-validates clean
    # regardless of the label's value — the label just has to be a real
    # stored row, not one that would already be refused today.
    app =
      AdminFixtures.insert_legacy_app!("legacy-collider")
      |> Ecto.Changeset.change(hostname_label: YouWeb.Endpoint.host())
      |> You.Repo.update!()

    # A degenerate but syntactically valid template (empty prefix/suffix),
    # configured *after* the row above was written, so the label now
    # renders to exactly the canonical host — the collision that only
    # exists because the template changed underneath it.
    enable_hostnames!("{label}")

    assert You.Hosting.render_hostname(app.hostname_label) == YouWeb.Endpoint.host()

    assert catch_exit(Mix.Tasks.You.AuditHostnameLabels.run([])) == {:shutdown, 1}

    assert_received {:mix_shell, :error, [summary]}
    assert summary =~ "1 app(s)"

    assert_received {:mix_shell, :info, [listing]}
    assert listing =~ app.hostname_label

    assert_received {:mix_shell, :info, [warning]}
    assert warning =~ "front door"
    assert warning =~ "APP_HOSTNAME_TEMPLATE"
  end
end
