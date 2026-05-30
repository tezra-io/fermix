defmodule FermixCore.Prompt.BootstrapRenameTest do
  use ExUnit.Case, async: true

  alias FermixCore.Prompt.BootstrapRename

  setup do
    unique = System.unique_integer([:positive])
    base_dir = Path.join(System.tmp_dir!(), "fermix-bootstrap-rename-#{unique}")
    File.mkdir_p!(base_dir)

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(base_dir) end)

    %{base_dir: base_dir}
  end

  test "renames a legacy AGENTS.md to FERMIX.md, preserving content", %{base_dir: base_dir} do
    agent_dir = Path.join(base_dir, "main")
    File.mkdir_p!(agent_dir)
    File.write!(Path.join(agent_dir, "AGENTS.md"), "operator edits")

    assert :ok = BootstrapRename.run(bootstrap_dir: base_dir)

    refute File.exists?(Path.join(agent_dir, "AGENTS.md"))
    assert File.read!(Path.join(agent_dir, "FERMIX.md")) == "operator edits"
  end

  test "is a no-op once already migrated", %{base_dir: base_dir} do
    agent_dir = Path.join(base_dir, "main")
    File.mkdir_p!(agent_dir)
    File.write!(Path.join(agent_dir, "FERMIX.md"), "already migrated")

    assert :ok = BootstrapRename.run(bootstrap_dir: base_dir)

    assert File.read!(Path.join(agent_dir, "FERMIX.md")) == "already migrated"
    refute File.exists?(Path.join(agent_dir, "AGENTS.md"))
  end

  test "does not clobber an existing FERMIX.md when a stale AGENTS.md remains", %{
    base_dir: base_dir
  } do
    agent_dir = Path.join(base_dir, "main")
    File.mkdir_p!(agent_dir)
    File.write!(Path.join(agent_dir, "AGENTS.md"), "stale legacy")
    File.write!(Path.join(agent_dir, "FERMIX.md"), "current")

    assert :ok = BootstrapRename.run(bootstrap_dir: base_dir)

    assert File.read!(Path.join(agent_dir, "FERMIX.md")) == "current"
  end

  test "returns :ok when the bootstrap directory does not exist", %{base_dir: base_dir} do
    assert :ok = BootstrapRename.run(bootstrap_dir: Path.join(base_dir, "nonexistent"))
  end
end
