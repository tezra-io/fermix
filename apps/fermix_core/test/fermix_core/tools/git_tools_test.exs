defmodule FermixCore.Tools.GitToolsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.GitRead
  alias FermixCore.Tools.GitWrite

  @context %{agent_name: "test_agent", conversation_key: :test}

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.cmd("git", ["init", "--initial-branch=main"], cd: dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: dir)
    File.write!(Path.join(dir, "README.md"), "# Test\n")
    System.cmd("git", ["add", "README.md"], cd: dir)
    System.cmd("git", ["commit", "-m", "initial"], cd: dir)
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

  test "git_read runs whitelisted read-only subcommands", %{dir: dir, context: context} do
    assert {:ok, result} =
             GitRead.execute(
               %{"repo" => dir, "command" => "status", "args" => ["--short"]},
               context
             )

    assert result.success == true
    assert result.output == ""
  end

  test "git_read denies a repo outside sandbox roots", %{context: context} do
    outside = FermixTestSupport.SafeRm.make_tmp_dir!("git-read-outside")
    System.cmd("git", ["init", "--initial-branch=main"], cd: outside)

    assert {:ok, result} =
             GitRead.execute(
               %{"repo" => outside, "command" => "status", "args" => []},
               context
             )

    assert result.success == false
    assert result.error =~ "outside_root" or result.error =~ "protected_path"

    FermixTestSupport.SafeRm.rm_rf!(outside)
  end

  test "git_write runs whitelisted mutating subcommands and rejects push", %{
    dir: dir,
    context: context
  } do
    File.write!(Path.join(dir, "README.md"), "# Changed\n")

    assert {:ok, add_result} =
             GitWrite.execute(
               %{"repo" => dir, "command" => "add", "args" => ["README.md"]},
               context
             )

    assert add_result.success == true

    assert {:ok, commit_result} =
             GitWrite.execute(
               %{"repo" => dir, "command" => "commit", "args" => ["-m", "change"]},
               context
             )

    assert commit_result.success == true

    assert {:ok, push_result} =
             GitWrite.execute(%{"repo" => dir, "command" => "push", "args" => []}, context)

    assert push_result.success == false
    assert push_result.error =~ "cannot push"
  end

  test "git_write rejects sandbox-escaping flags incl. abbreviations (argument injection)", %{
    dir: dir,
    context: context
  } do
    # `git pull --upload-pack=<cmd>` runs <cmd> for the file:// transport — a
    # classic argument-injection-to-RCE primitive. git also honors unambiguous
    # prefix abbreviations of long options, so the abbreviated form must be
    # rejected too. `true` is a harmless stand-in for the injected command.
    dangerous = [
      ["--upload-pack=true", "file:///tmp/fermix_nonexistent_xyz"],
      ["--upload-pac=true", "file:///tmp/fermix_nonexistent_xyz"],
      ["--upload-pack", "true"],
      ["--receive-pack=true", "file:///tmp/fermix_nonexistent_xyz"],
      ["--git-dir=/tmp/other.git"],
      ["--exec-path=/tmp"],
      ["--output=/tmp/leak"]
    ]

    for args <- dangerous do
      assert {:ok, result} =
               GitWrite.execute(%{"repo" => dir, "command" => "pull", "args" => args}, context)

      assert result.success == false, "expected #{inspect(args)} to be rejected"

      assert result.error =~ "escape sandbox containment",
             "expected sandbox-containment rejection for #{inspect(args)}, got: #{result.error}"
    end
  end

  test "git_write pull refuses the ext:: transport even under a permissive host git config", %{
    dir: dir,
    context: context
  } do
    # git's `ext::<program>` smart-transport helper runs an arbitrary program
    # before any handshake — argument-injection-to-RCE that never touches the
    # command classifier. Modern git refuses `ext` by default, but a permissive
    # host config (`protocol.ext.allow=user`) re-enables it, so the sandbox must
    # not depend on the ambient git config. GitCommand pins GIT_ALLOW_PROTOCOL,
    # which overrides that config. `% ` is the ext URL's literal-space escape, so
    # the payload is `sh -c "touch <marker>"`; the marker lives under `dir`
    # (SafeRm-cleaned) and must never be created.
    System.cmd("git", ["config", "protocol.ext.allow", "user"], cd: dir)
    marker = Path.join(dir, "pwned_#{System.unique_integer([:positive])}")
    refute File.exists?(marker)

    assert {:ok, result} =
             GitWrite.execute(
               %{"repo" => dir, "command" => "pull", "args" => ["ext::sh -c touch% #{marker}"]},
               context
             )

    assert result.success == false

    refute File.exists?(marker),
           "ext:: transport executed the payload — command-classification sandbox bypassed"

    assert result.error =~ "not allowed",
           "expected git to refuse the ext transport, got: #{result.error}"
  end

  test "git_write does not over-reject commit messages that resemble paths", %{
    dir: dir,
    context: context
  } do
    File.write!(Path.join(dir, "README.md"), "# Changed\n")

    {:ok, _} =
      GitWrite.execute(%{"repo" => dir, "command" => "add", "args" => ["README.md"]}, context)

    # Positional path containment (absolute / `..`) is a read-tool concern; it
    # must not reject legitimate commit messages that happen to look like paths.
    assert {:ok, result} =
             GitWrite.execute(
               %{
                 "repo" => dir,
                 "command" => "commit",
                 "args" => ["-m", "/etc/hosts: noted the ../old path"]
               },
               context
             )

    assert result.success == true,
           "commit message resembling a path was wrongly rejected: #{inspect(result)}"
  end

  test "git_write denies repo outside sandbox roots", %{context: context} do
    outside = FermixTestSupport.SafeRm.make_tmp_dir!("git-outside")
    System.cmd("git", ["init", "--initial-branch=main"], cd: outside)

    assert {:ok, result} =
             GitWrite.execute(%{"repo" => outside, "command" => "add", "args" => ["."]}, context)

    assert result.success == false
    assert result.error =~ "outside roots"
    assert result.error =~ "fermix grant path #{PathPolicy.canonical_path(outside)}"

    FermixTestSupport.SafeRm.rm_rf!(outside)
  end

  test "git_write suggests repo root when cwd is allowed but repo root is denied", %{dir: dir} do
    nested = Path.join(dir, "nested")
    File.mkdir_p!(nested)

    context =
      Map.put(
        @context,
        :sandbox_config,
        Config.normalize(mode: :strict, workspace_root: nested)
      )

    assert {:ok, result} =
             GitWrite.execute(%{"repo" => nested, "command" => "add", "args" => ["."]}, context)

    assert result.success == false
    assert result.error =~ "outside roots"
    assert result.error =~ "resolved from input #{PathPolicy.canonical_path(nested)}"
    assert result.error =~ "fermix grant path #{PathPolicy.canonical_path(dir)}"
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
