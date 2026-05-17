defmodule FermixCore.Sandbox.ConfigMutationTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.ConfigMutation
  alias FermixCore.Sandbox.PathPolicy

  test "adds and removes allowed roots with confirmation diff signal" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mutation")
    root = Path.join(home, "project")
    File.mkdir_p!(root)

    config =
      Config.normalize(home: home, mode: :strict, workspace_root: Path.join(home, "workspace"))

    assert {:ok, widened} = ConfigMutation.add_allowed_root(config, root)
    assert ConfigMutation.requires_confirmation?(config, widened)
    assert ConfigMutation.diff(config, widened) =~ "allowed_roots +"

    assert {:ok, narrowed} = ConfigMutation.remove_allowed_root(widened, root)
    refute ConfigMutation.requires_confirmation?(widened, narrowed)

    FermixTestSupport.SafeRm.rm_rf!(home)
  end

  test "rejects unsafe root grants" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mutation")
    fermix_home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-fermix-home")
    previous_home = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", fermix_home)

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(fermix_home)
    end)

    config =
      Config.normalize(
        home: home,
        mode: :strict,
        workspace_root: Path.join(home, "workspace")
      )

    etc = PathPolicy.canonical_path("/etc")

    assert {:error, {:unsafe_root, "/"}} = ConfigMutation.add_allowed_root(config, "/")
    assert {:error, {:unsafe_root, ^etc}} = ConfigMutation.add_allowed_root(config, "/etc")
    canonical_home = PathPolicy.canonical_path(home)

    assert {:error, {:unsafe_root, ^canonical_home}} = ConfigMutation.add_allowed_root(config, home)

    canonical_fermix_home = PathPolicy.canonical_path(fermix_home)

    assert {:error, {:unsafe_root, ^canonical_fermix_home}} =
             ConfigMutation.add_allowed_root(config, fermix_home)

    FermixTestSupport.SafeRm.rm_rf!(home)
  end

  test "enables and disables command capabilities with confirmation diff signal" do
    config = Config.normalize(commands: [profile: :bare])

    spec = %{
      "command" => "/bin/echo",
      "args" => ["hello"],
      "pass_env" => ["FERMIX_TEST_SECRET"]
    }

    assert {:ok, widened} = ConfigMutation.enable_command(config, "echo_test", spec)
    assert ConfigMutation.requires_confirmation?(config, widened)
    assert ConfigMutation.diff(config, widened) =~ "commands + echo_test"
    assert widened.commands.explicit["echo_test"].enabled == true

    assert {:ok, narrowed} = ConfigMutation.disable_command(widened, "echo_test")
    refute ConfigMutation.requires_confirmation?(widened, narrowed)
    refute narrowed.commands.explicit["echo_test"].enabled
  end
end
