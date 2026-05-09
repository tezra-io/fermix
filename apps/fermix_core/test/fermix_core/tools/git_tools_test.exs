defmodule FermixCore.Tools.GitToolsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Tools.GitRead
  alias FermixCore.Tools.GitWrite

  @context %{agent_name: "test_agent", conversation_key: :test}

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.cmd("git", ["init"], cd: dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: dir)
    File.write!(Path.join(dir, "README.md"), "# Test\n")
    System.cmd("git", ["add", "README.md"], cd: dir)
    System.cmd("git", ["commit", "-m", "initial"], cd: dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "git_read runs whitelisted read-only subcommands", %{dir: dir} do
    assert {:ok, result} =
             GitRead.execute(
               %{"repo" => dir, "command" => "status", "args" => ["--short"]},
               @context
             )

    assert result.success == true
    assert result.output == ""
  end

  test "git_write runs whitelisted mutating subcommands and rejects push", %{dir: dir} do
    File.write!(Path.join(dir, "README.md"), "# Changed\n")

    assert {:ok, add_result} =
             GitWrite.execute(
               %{"repo" => dir, "command" => "add", "args" => ["README.md"]},
               @context
             )

    assert add_result.success == true

    assert {:ok, commit_result} =
             GitWrite.execute(
               %{"repo" => dir, "command" => "commit", "args" => ["-m", "change"]},
               @context
             )

    assert commit_result.success == true

    assert {:ok, push_result} =
             GitWrite.execute(%{"repo" => dir, "command" => "push", "args" => []}, @context)

    assert push_result.success == false
    assert push_result.error =~ "M10"
  end

  test "registry policy exposes git_read to read-only filters but not git_write" do
    name = :"git_policy_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    :ok = Registry.register(name, Builtin.from_tool_module(GitRead))
    :ok = Registry.register(name, Builtin.from_tool_module(GitWrite))

    assert ["git_read"] =
             name
             |> Registry.list(policy: [allow: [:read_only]])
             |> Enum.map(& &1.name)
  end
end
