defmodule FermixCore.Tools.SearchToolsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.ContentSearch
  alias FermixCore.Tools.GlobSearch

  @context %{agent_name: "test_agent", conversation_key: :test}

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix-search-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/alpha.ex"), "defmodule Alpha do\n  # TODO first\nend\n")
    File.write!(Path.join(dir, "lib/beta.ex"), "defmodule Beta do\n  @tag :ok\nend\n")
    File.write!(Path.join(dir, "notes.txt"), "TODO second\n")
    File.write!(Path.join(dir, "binary.bin"), <<0, 1, 2, 3, 84, 79, 68, 79>>)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "glob_search returns bounded absolute path matches", %{dir: dir} do
    assert {:ok, result} =
             GlobSearch.execute(
               %{"path" => dir, "pattern" => "**/*.ex", "max_results" => 1},
               @context
             )

    assert result.success == true
    [path] = Jason.decode!(result.output)
    assert Path.type(path) == :absolute
    assert String.ends_with?(path, ".ex")
  end

  test "content_search finds text matches and skips binary files", %{dir: dir} do
    assert {:ok, result} =
             ContentSearch.execute(
               %{"path" => dir, "pattern" => "TODO", "max_results" => 10},
               @context
             )

    assert result.success == true
    payload = Jason.decode!(result.output)
    assert length(payload["matches"]) == 2
    refute Enum.any?(payload["matches"], &String.ends_with?(&1["path"], "binary.bin"))
  end

  test "content_search supports regex and reports invalid regex loudly", %{dir: dir} do
    assert {:ok, ok} =
             ContentSearch.execute(
               %{"path" => dir, "pattern" => "defmodule\\s+Alpha", "regex" => true},
               @context
             )

    assert ok.success == true
    assert [%{"line" => 1}] = Jason.decode!(ok.output)["matches"]

    assert {:ok, bad} =
             ContentSearch.execute(
               %{"path" => dir, "pattern" => "[", "regex" => true},
               @context
             )

    assert bad.success == false
    assert bad.error =~ "invalid_regex"
  end
end
