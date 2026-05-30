defmodule FermixCore.Tools.GlobSearchTest do
  use ExUnit.Case, async: true

  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.GlobSearch

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix_glob_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), "alpha")
    File.write!(Path.join(dir, "b.txt"), "beta")
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join([dir, "sub", "c.txt"]), "gamma")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    context = %{
      agent_name: "test_agent",
      conversation_key: :test,
      cwd: dir,
      sandbox_config: %{mode: :strict, workspace_root: dir, allowed_roots: []}
    }

    %{dir: dir, context: context}
  end

  test "lists files inside the sandbox root", %{dir: dir, context: context} do
    assert {:ok, result} =
             GlobSearch.execute(%{"pattern" => "**/*.txt", "path" => dir}, context)

    assert result.success == true
    payload = Jason.decode!(result.output)
    assert length(payload) == 3
    assert Enum.all?(payload, &String.ends_with?(&1, ".txt"))
    canonical = PathPolicy.canonical_path(dir)
    assert Enum.all?(payload, &String.starts_with?(&1, canonical))
  end

  test "rejects a root outside the sandbox", %{context: context} do
    outside =
      Path.join(System.tmp_dir!(), "fermix_glob_outside_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(outside) end)

    assert {:ok, result} =
             GlobSearch.execute(%{"pattern" => "*.txt", "path" => outside}, context)

    assert result.success == false
    assert result.error =~ "outside_root" or result.error =~ "protected_path"
  end
end
