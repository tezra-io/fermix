defmodule FermixCore.Tools.GitReadTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.GitRead

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix_git_read_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    context = %{
      agent_name: "test_agent",
      conversation_key: :test,
      cwd: dir,
      sandbox_config: %{mode: :strict, workspace_root: dir, allowed_roots: []}
    }

    %{dir: dir, context: context}
  end

  test "rejects a repo path outside the sandbox", %{context: context} do
    outside =
      Path.join(
        System.tmp_dir!(),
        "fermix_git_read_outside_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(outside) end)

    assert {:ok, result} =
             GitRead.execute(%{"command" => "status", "repo" => outside}, context)

    assert result.success == false
    assert result.error =~ "outside_root" or result.error =~ "protected_path"
  end

  test "rejects an unknown subcommand inside the sandbox", %{context: context, dir: dir} do
    assert {:ok, result} =
             GitRead.execute(%{"command" => "push", "repo" => dir}, context)

    assert result.success == false
    assert result.error =~ "unknown_command"
  end
end
