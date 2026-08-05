defmodule Mix.Tasks.You.AuditSlugsTest do
  @moduledoc """
  `mix you.audit_slugs` reports rows written before slug validation existed,
  so enabling the rule does not silently leave an app nobody can edit.
  """
  use You.DataCase, async: false

  alias You.Admin.App

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp insert_legacy_app!(slug) do
    %App{}
    |> Ecto.Changeset.change(%{
      slug: slug,
      name: "Legacy",
      callback_url: "https://legacy-#{System.unique_integer([:positive])}.example.com/cb",
      allowed_roles: ["user", "admin"],
      default_role: "user"
    })
    |> You.Repo.insert!()
  end

  test "reports success when every slug satisfies the rule" do
    Mix.Tasks.You.AuditSlugs.run([])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "All app slugs satisfy"
  end

  test "reports offending apps and warns that renaming breaks consumers" do
    app = insert_legacy_app!("legacy.app")

    Mix.Tasks.You.AuditSlugs.run([])

    assert_received {:mix_shell, :error, [summary]}
    assert summary =~ "1 app(s)"

    assert_received {:mix_shell, :info, [listing]}
    assert listing =~ app.slug

    assert_received {:mix_shell, :info, [warning]}
    assert warning =~ "client_id"
    assert warning =~ "breaks every consumer"
  end
end
