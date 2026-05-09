defmodule FermixCore.Tools.FileEditTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.FileEdit

  @context %{agent_name: "test_agent", conversation_key: :test}

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix-file-edit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "replaces a unique anchor string atomically", %{dir: dir} do
    path = Path.join(dir, "sample.txt")
    File.write!(path, "alpha\nneedle\nomega\n")

    assert {:ok, result} =
             FileEdit.execute(
               %{"path" => path, "old_string" => "needle", "new_string" => "replacement"},
               @context
             )

    assert result.success == true
    assert result.output =~ "Replaced"
    assert File.read!(path) == "alpha\nreplacement\nomega\n"
  end

  test "refuses to edit when the anchor is absent", %{dir: dir} do
    path = Path.join(dir, "sample.txt")
    File.write!(path, "alpha\nomega\n")

    assert {:ok, result} =
             FileEdit.execute(
               %{"path" => path, "old_string" => "needle", "new_string" => "replacement"},
               @context
             )

    assert result.success == false
    assert result.error =~ "not found"
    assert File.read!(path) == "alpha\nomega\n"
  end

  test "refuses to edit when the anchor is not unique", %{dir: dir} do
    path = Path.join(dir, "sample.txt")
    File.write!(path, "needle\nneedle\n")

    assert {:ok, result} =
             FileEdit.execute(
               %{"path" => path, "old_string" => "needle", "new_string" => "replacement"},
               @context
             )

    assert result.success == false
    assert result.error =~ "unique"
    assert File.read!(path) == "needle\nneedle\n"
  end
end
