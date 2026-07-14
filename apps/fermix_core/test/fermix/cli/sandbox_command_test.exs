defmodule Fermix.CLI.SandboxCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.SandboxCommand
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.PathPolicy

  setup do
    sandbox = Application.get_env(:fermix_core, :sandbox)
    fermix_home = System.get_env("FERMIX_HOME")
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-command")

    System.put_env("FERMIX_HOME", home)

    Application.put_env(
      :fermix_core,
      :sandbox,
      Config.normalize(
        home: home,
        mode: :strict,
        workspace_root: Path.join(home, "workspace"),
        allowed_roots: [Path.join(home, "project")],
        env: [allow: ["OPENAI_API_KEY"]]
      )
    )

    on_exit(fn ->
      case sandbox do
        nil -> Application.delete_env(:fermix_core, :sandbox)
        value -> Application.put_env(:fermix_core, :sandbox, value)
      end

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    :ok
  end

  test "status prints compact sandbox summary" do
    output = capture_io(fn -> assert SandboxCommand.run(["status"]) == 0 end)

    assert output =~ "mode: strict"
    assert output =~ "workspace:"
    assert output =~ "allowed roots:"
    assert output =~ "env passthrough:"
  end

  test "explain prints effective policy without env values" do
    output = capture_io(fn -> assert SandboxCommand.run(["explain"]) == 0 end)

    assert output =~ "effective roots:"
    assert output =~ "protected paths:"
    assert output =~ "OPENAI_API_KEY"
    refute output =~ "sk-"
  end

  test "explain annotates effective roots with granted vs mode provenance" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-explain-provenance")
    workspace = Path.join(home, "workspace")
    granted = Path.join(home, "granted-proj")
    File.mkdir_p!(workspace)
    File.mkdir_p!(granted)

    Application.put_env(
      :fermix_core,
      :sandbox,
      Config.normalize(
        home: home,
        os_home: home,
        mode: :strict,
        workspace_root: workspace,
        allowed_roots: [granted]
      )
    )

    output = capture_io(fn -> assert SandboxCommand.run(["explain"]) == 0 end)

    assert output =~ "effective roots:"
    assert output =~ "  - #{PathPolicy.canonical_path(granted)} (granted)"
    assert output =~ "  - #{PathPolicy.canonical_path(workspace)} (mode)"

    FermixTestSupport.SafeRm.rm_rf!(home)
  end

  test "mode command persists sandbox mode" do
    output = capture_io(fn -> assert SandboxCommand.run(["mode", "standard"]) == 0 end)

    assert output =~ "mode: standard"
    assert Config.current().mode == :standard
  end

  test "grant and revoke path persist allowed roots" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-grant")

    grant_output = capture_io(fn -> assert SandboxCommand.run(["grant", "path", root]) == 0 end)
    assert grant_output =~ "granted:"
    assert PathPolicy.canonical_path(root) in Config.current().allowed_roots

    revoke_output = capture_io(fn -> assert SandboxCommand.run(["revoke", "path", root]) == 0 end)
    assert revoke_output =~ "revoked:"
    refute PathPolicy.canonical_path(root) in Config.current().allowed_roots

    FermixTestSupport.SafeRm.rm_rf!(root)
  end

  test "grant rejects unsafe roots" do
    output =
      capture_io(:stderr, fn ->
        assert SandboxCommand.run(["grant", "path", "/"]) == 1
      end)

    assert output =~ "unsafe_root"
    assert output =~ "fermix sandbox explain"
  end

  test "env get failure names the reconfiguration command" do
    output =
      capture_io(:stderr, fn ->
        assert SandboxCommand.run(["env", "get", "MISSING_SECRET"]) == 1
      end)

    assert output =~ "MISSING_SECRET"
    assert output =~ "fermix sandbox env allow MISSING_SECRET"
  end

  test "env allow and unset persist selected env names" do
    allow_output =
      capture_io(fn -> assert SandboxCommand.run(["env", "allow", "OPENAI_API_KEY"]) == 0 end)

    assert allow_output =~ "env allowed"
    assert "OPENAI_API_KEY" in Config.current().env.allow

    unset_output =
      capture_io(fn -> assert SandboxCommand.run(["env", "unset", "OPENAI_API_KEY"]) == 0 end)

    assert unset_output =~ "env removed"
    refute "OPENAI_API_KEY" in Config.current().env.allow
  end

  test "env set stores command source and get masks resolved value by default" do
    set_output =
      capture_io(fn ->
        assert SandboxCommand.run(["env", "set", "OPENAI_API_KEY", "--", "/bin/echo", "sk-test"]) ==
                 0
      end)

    assert set_output =~ "env source set: OPENAI_API_KEY"
    assert Config.current().env.sources["OPENAI_API_KEY"].source == :command
    assert Config.current().env.sources["OPENAI_API_KEY"].command == "/bin/echo"

    get_output =
      capture_io(fn ->
        assert SandboxCommand.run(["env", "get", "OPENAI_API_KEY"]) == 0
      end)

    assert get_output =~ "OPENAI_API_KEY=***"
    refute get_output =~ "sk-test"

    unsafe_output =
      capture_io(fn ->
        assert SandboxCommand.run(["env", "get", "OPENAI_API_KEY", "--unsafe-print"]) == 0
      end)

    assert unsafe_output =~ "OPENAI_API_KEY=sk-test"
  end

  test "command profile and explicit command grants persist" do
    profile_output =
      capture_io(fn ->
        assert SandboxCommand.run(["commands", "profile", "assistant"]) == 0
      end)

    assert profile_output =~ "command profile: assistant"
    assert Config.current().commands.profile == :assistant

    grant_output =
      capture_io(fn ->
        assert SandboxCommand.run(["grant", "command", "echo_test", "--", "/bin/echo", "hello"]) ==
                 0
      end)

    assert grant_output =~ "command granted: echo_test"
    assert Config.current().commands.explicit["echo_test"].command == "/bin/echo"
    assert Config.current().commands.explicit["echo_test"].args == ["hello"]
  end
end
