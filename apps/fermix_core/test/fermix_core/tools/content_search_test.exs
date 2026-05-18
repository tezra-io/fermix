defmodule FermixCore.Tools.ContentSearchTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.ContentSearch

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix_csearch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), "hello world\ngoodbye world")
    File.write!(Path.join(dir, "b.txt"), "no match here")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    context = %{
      agent_name: "test_agent",
      conversation_key: :test,
      cwd: dir,
      sandbox_config: %{mode: :strict, workspace_root: dir, allowed_roots: []}
    }

    %{dir: dir, context: context}
  end

  test "finds matches inside the sandbox root", %{dir: dir, context: context} do
    assert {:ok, result} =
             ContentSearch.execute(%{"pattern" => "hello", "path" => dir}, context)

    assert result.success == true
    payload = Jason.decode!(result.output)
    assert is_list(payload["matches"])
    assert Enum.any?(payload["matches"], &(&1["text"] =~ "hello world"))
  end

  test "rejects a root outside the sandbox", %{context: context} do
    outside =
      Path.join(System.tmp_dir!(), "fermix_csearch_outside_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(outside) end)

    assert {:ok, result} =
             ContentSearch.execute(%{"pattern" => "hello", "path" => outside}, context)

    assert result.success == false
    assert result.error =~ "outside_root" or result.error =~ "protected_path"
  end
end
