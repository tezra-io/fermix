defmodule FermixCore.Tools.FileEditTest do
  use ExUnit.Case, async: true

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.FileEdit

  @context %{agent_name: "test_agent", conversation_key: :test}

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix-file-edit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    %{
      dir: dir,
      context:
        Map.put(
          @context,
          :sandbox_config,
          Config.normalize(mode: :strict, workspace_root: dir)
        )
    }
  end

  test "replaces a unique anchor string atomically", %{dir: dir, context: context} do
    path = Path.join(dir, "sample.txt")
    File.write!(path, "alpha\nneedle\nomega\n")

    assert {:ok, result} =
             FileEdit.execute(
               %{"path" => path, "old_string" => "needle", "new_string" => "replacement"},
               context
             )

    assert result.success == true
    assert result.output =~ "Replaced"
    assert File.read!(path) == "alpha\nreplacement\nomega\n"
  end

  test "refuses to edit when the anchor is absent", %{dir: dir, context: context} do
    path = Path.join(dir, "sample.txt")
    File.write!(path, "alpha\nomega\n")

    assert {:ok, result} =
             FileEdit.execute(
               %{"path" => path, "old_string" => "needle", "new_string" => "replacement"},
               context
             )

    assert result.success == false
    assert result.error =~ "not found"
    assert File.read!(path) == "alpha\nomega\n"
  end

  test "refuses to edit when the anchor is not unique", %{dir: dir, context: context} do
    path = Path.join(dir, "sample.txt")
    File.write!(path, "needle\nneedle\n")

    assert {:ok, result} =
             FileEdit.execute(
               %{"path" => path, "old_string" => "needle", "new_string" => "replacement"},
               context
             )

    assert result.success == false
    assert result.error =~ "unique"
    assert File.read!(path) == "needle\nneedle\n"
  end

  test "refuses symlink escapes", %{dir: dir, context: context} do
    outside = FermixTestSupport.SafeRm.make_tmp_dir!("file-edit-outside")
    outside_file = Path.join(outside, "target.txt")
    link = Path.join(dir, "link.txt")
    File.write!(outside_file, "alpha\nneedle\nomega\n")
    File.ln_s!(outside_file, link)

    assert {:ok, result} =
             FileEdit.execute(
               %{"path" => link, "old_string" => "needle", "new_string" => "replacement"},
               context
             )

    assert result.success == false
    assert result.error =~ "outside roots"
    assert result.error =~ "fermix grant path #{PathPolicy.canonical_path(outside)}"
    assert File.read!(outside_file) == "alpha\nneedle\nomega\n"

    FermixTestSupport.SafeRm.rm_rf!(outside)
  end
end
