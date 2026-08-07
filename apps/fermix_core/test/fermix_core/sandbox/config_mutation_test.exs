defmodule FermixCore.Sandbox.ConfigMutationTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Sandbox.CommandCapabilities
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.ConfigMutation
  alias FermixCore.Sandbox.PathPolicy

  # Captures the opts every keyring read/write receives so the persist/2 →
  # ConfigStore → SecretStore → SecretWriter → CommandRunner threading is
  # observable. `get` returns a different value per call so the secure pass
  # sees a rotation and exercises the keyring WRITE path too.
  defmodule RotatingRecordingWriter do
    @behaviour FermixCore.Setup.SecretWriter

    @table __MODULE__

    def start do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :ordered_set])
      end

      :ets.delete_all_objects(@table)
      :ok
    end

    def recorded(kind) do
      @table
      |> :ets.tab2list()
      |> Enum.filter(fn {_n, k, _opts} -> k == kind end)
      |> Enum.map(fn {_n, _k, opts} -> opts end)
    end

    defp record(kind, opts) do
      n = :erlang.unique_integer([:monotonic, :positive])
      :ets.insert(@table, {n, kind, opts})
      n
    end

    @impl true
    def available?(_opts \\ []), do: true

    @impl true
    def get(_key, opts \\ []), do: {:ok, "rotated-#{record(:get, opts)}"}

    @impl true
    def put(_key, _value, opts \\ []) do
      record(:put, opts)
      :ok
    end

    @impl true
    def delete(_key, _opts \\ []), do: raise("sandbox config mutation must never delete a secret")

    @impl true
    def command_source(key, _opts \\ []) do
      %{source: :command, command: "recording", args: [Atom.to_string(key)]}
    end
  end

  describe "persist/2 supervised threading (tree-less fermix grant chain)" do
    setup do
      core = Application.get_all_env(:fermix_core)
      channels = Application.get_all_env(:fermix_channels)
      previous_home = System.get_env("FERMIX_HOME")

      :ok = RotatingRecordingWriter.start()
      Application.put_env(:fermix_core, :secret_writer, RotatingRecordingWriter)

      tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("config-mutation-persist")
      System.put_env("FERMIX_HOME", tmp_home)

      File.write!(Path.join(tmp_home, "config.toml"), """
      [fermix_core.providers.openai]
      api_key = "@keyring"
      """)

      on_exit(fn ->
        case previous_home do
          nil -> System.delete_env("FERMIX_HOME")
          value -> System.put_env("FERMIX_HOME", value)
        end

        Enum.each(core, fn {k, v} -> Application.put_env(:fermix_core, k, v) end)
        Enum.each(channels, fn {k, v} -> Application.put_env(:fermix_channels, k, v) end)

        if Process.whereis(CapabilityRegistry) do
          CommandCapabilities.refresh(CapabilityRegistry, Config.current())
        end

        FermixTestSupport.SafeRm.rm_rf!(tmp_home)
      end)

      {:ok, tmp_home: tmp_home}
    end

    test "threads supervised: false through resolution reads and keyring writes", %{
      tmp_home: tmp_home
    } do
      config =
        Config.normalize(
          home: tmp_home,
          mode: :strict,
          workspace_root: Path.join(tmp_home, "workspace")
        )

      assert :ok = ConfigMutation.persist(config, supervised: false)

      gets = RotatingRecordingWriter.recorded(:get)
      puts = RotatingRecordingWriter.recorded(:put)

      assert gets != [], "persist resolved no keyring sentinel"
      assert puts != [], "the rotating writer should force one keyring write"

      for opts <- gets ++ puts do
        assert Keyword.get(opts, :supervised) == false,
               "a grant-chain keyring call ran without supervised: false: #{inspect(opts)}"
      end
    end
  end

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

    assert {:error, {:unsafe_root, ^canonical_home}} =
             ConfigMutation.add_allowed_root(config, home)

    canonical_fermix_home = PathPolicy.canonical_path(fermix_home)

    assert {:error, {:unsafe_root, ^canonical_fermix_home}} =
             ConfigMutation.add_allowed_root(config, fermix_home)

    FermixTestSupport.SafeRm.rm_rf!(home)
  end

  test "refuses a grant of the OS home wholesale" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mutation-oshome")

    config =
      Config.normalize(
        mode: :standard,
        os_home: os_home,
        workspace_root: Path.join(os_home, "workspace")
      )

    canonical = PathPolicy.canonical_path(os_home)

    assert {:error, {:unsafe_root, ^canonical}} =
             ConfigMutation.add_allowed_root(config, os_home)

    FermixTestSupport.SafeRm.rm_rf!(os_home)
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
