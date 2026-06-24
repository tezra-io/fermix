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

  test "rejects `--no-index` (would read absolute paths outside the repo)", %{
    context: context,
    dir: dir
  } do
    assert {:ok, result} =
             GitRead.execute(
               %{"command" => "diff", "repo" => dir, "args" => ["--no-index"]},
               context
             )

    assert result.success == false
    assert result.error =~ "--no-index"
  end

  test "rejects `--git-dir=` (would redirect git's view of the repo)", %{
    context: context,
    dir: dir
  } do
    assert {:ok, result} =
             GitRead.execute(
               %{
                 "command" => "status",
                 "repo" => dir,
                 "args" => ["--git-dir=/some/other/.git"]
               },
               context
             )

    assert result.success == false
    assert result.error =~ "--git-dir="
  end

  test "rejects an absolute-path positional arg", %{context: context, dir: dir} do
    assert {:ok, result} =
             GitRead.execute(
               %{"command" => "log", "repo" => dir, "args" => ["/etc/passwd"]},
               context
             )

    assert result.success == false
    assert result.error =~ "absolute path"
  end

  test "rejects `..`-bearing positional args", %{context: context, dir: dir} do
    assert {:ok, result} =
             GitRead.execute(
               %{"command" => "log", "repo" => dir, "args" => ["../../etc/passwd"]},
               context
             )

    assert result.success == false
    assert result.error =~ "outside the repo"
  end

  test "accepts legitimate flag-style args like --short, --oneline, refs/heads/main", %{
    context: context,
    dir: dir
  } do
    System.cmd("git", ["init", "--initial-branch=main"], cd: dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    File.write!(Path.join(dir, "f.txt"), "hi")
    System.cmd("git", ["add", "f.txt"], cd: dir)
    System.cmd("git", ["commit", "-m", "init"], cd: dir)

    assert {:ok, ok_short} =
             GitRead.execute(
               %{"command" => "status", "repo" => dir, "args" => ["--short"]},
               context
             )

    assert ok_short.success == true

    assert {:ok, ok_log} =
             GitRead.execute(
               %{"command" => "log", "repo" => dir, "args" => ["--oneline", "refs/heads/main"]},
               context
             )

    assert ok_log.success == true
  end
end
