defmodule You.Audit.ReaderTest do
  use ExUnit.Case, async: false

  alias You.Audit.Reader

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "you_audit_reader_#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    # Write some test data
    File.write!(Path.join(tmp_dir, "login.jsonl"), """
    {"ts":"2026-01-01T00:00:00Z","event":"login:attempt","user_id":1,"email":"a@b.com","result":"success"}
    {"ts":"2026-01-02T00:00:00Z","event":"login:attempt","user_id":1,"email":"a@b.com","result":"failure"}
    """)

    %{tmp_dir: tmp_dir}
  end

  describe "categories/0" do
    test "lists available log categories" do
      assert Reader.categories() |> is_list()
    end
  end

  describe "read/2" do
    test "reads events newest first" do
      events = Reader.read("login")
      assert is_list(events)
    end
  end
end
