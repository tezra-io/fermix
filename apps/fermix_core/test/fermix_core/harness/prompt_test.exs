defmodule FermixCore.Harness.PromptTest do
  # Writes only into per-test SafeRm tmp dirs, so runs stay isolated.
  use ExUnit.Case, async: true

  import Bitwise, only: [{:&&&, 2}]

  alias FermixCore.Harness.Prompt

  setup do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("harness-prompt")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a small prompt passes through inline as argv", %{dir: dir} do
    assert {:ok, {:argv, "do the thing"}} = Prompt.transport("do the thing", dir)
  end

  test "a prompt exactly at the cap stays inline", %{dir: dir} do
    exact = String.duplicate("y", 16)
    assert {:ok, {:argv, ^exact}} = Prompt.transport(exact, dir, max_argv_bytes: 16)
  end

  test "an oversized prompt spills to a 0600 brief with a pointer", %{dir: dir} do
    big = String.duplicate("x", 32)

    assert {:ok, {:brief, pointer, path}} = Prompt.transport(big, dir, max_argv_bytes: 16)

    assert path == Path.join(dir, "brief.md")
    assert File.read!(path) == big
    assert file_mode(path) == 0o600
    assert pointer == "Your full brief is at #{path}. Read it first, then execute it."
  end

  test "brief content is byte-identical for a large prompt over the default cap", %{dir: dir} do
    big = String.duplicate("abc\n", 100_000)
    assert byte_size(big) > 200 * 1024

    assert {:ok, {:brief, _pointer, path}} = Prompt.transport(big, dir)
    assert File.read!(path) == big
  end

  test "a missing artifacts dir is refused for an oversized prompt", %{dir: dir} do
    missing = Path.join(dir, "does-not-exist")

    assert {:error, {:missing_dir, ^missing}} =
             Prompt.transport(String.duplicate("x", 32), missing, max_argv_bytes: 16)
  end

  test "an empty prompt is refused", %{dir: dir} do
    assert {:error, :empty_prompt} = Prompt.transport("", dir)
  end

  test "a relative artifacts dir is refused" do
    assert {:error, :relative_dir} = Prompt.transport("x", "relative/dir")
  end

  test "a non-positive max_argv_bytes fails loud", %{dir: dir} do
    assert_raise ArgumentError, ~r/max_argv_bytes/, fn ->
      Prompt.transport("x", dir, max_argv_bytes: 0)
    end
  end

  defp file_mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    mode &&& 0o777
  end
end
