defmodule You.ReleaseTest do
  @moduledoc """
  Only the non-halting path of `audit_slugs/0` is covered here.
  `System.halt/1` stops the whole BEAM node, not just the calling process —
  unlike `exit/1` in `Mix.Tasks.You.AuditSlugs`, it cannot be caught from
  inside the test that triggers it, which is also why no other `You.Release`
  function exercises its halting branch in this suite.
  """
  use You.DataCase, async: false

  alias You.Admin

  test "audit_slugs/0 reports success to stdout when every slug satisfies the rule" do
    {:ok, _app, _secret} =
      Admin.create_app(%{
        slug: "clean-app",
        name: "Clean",
        callback_url: "https://clean.example.com/cb"
      })

    assert Admin.apps_with_invalid_slug() == []
    assert ExUnit.CaptureIO.capture_io(&You.Release.audit_slugs/0) =~ "All app slugs satisfy"
  end
end
