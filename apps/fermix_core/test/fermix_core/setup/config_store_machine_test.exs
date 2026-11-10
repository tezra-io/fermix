defmodule FermixCore.Setup.ConfigStoreMachineTest do
  # M97 §4: this computer's own settings live in `machine.toml`, beside
  # `config.toml`. async: false, since the store reads FERMIX_HOME from the
  # environment, and the boot test applies application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory.Config, as: ComputerHistoryConfig
  alias FermixCore.ComputerUse.Config, as: ComputerUseConfig
  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.Candidate
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.MachineFile
  alias FermixTestSupport.SafeRm

  # Every application whose environment a load or a boot writes; restored
  # whole, so nothing this module applies reaches another.
  @apps [:fermix_core, :fermix_channels, :fermix_web]

  # A home an earlier engine wrote, from an invented Mac: the home's settings
  # and the computer's own in one file.
  @old_config """
  [fermix_core.agent]
  name = "Orchard"

  [sandbox]
  # this Mac's own
  mode = "strict"
  allowed_roots = ["/Users/invented/Projects"]

  [fermix_core.computer_use]
  enabled = true

  [fermix_core.plugins]
  dev_local = "/Users/invented/dev-plugins"

  [fermix_channels.imessage]
  enabled = true
  owner_user_id = "+15550100231"
  """

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_env = for app <- @apps, do: {app, Application.get_all_env(app)}

    FermixTestSupport.SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)

    tmp = SafeRm.make_tmp_dir!("config-store-machine")
    home = Path.join(tmp, "home")
    File.mkdir!(home)
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      Enum.each(previous_env, &restore_env/1)
      FermixTestSupport.SecretWriterStub.reset()

      if previous_home,
        do: System.put_env("FERMIX_HOME", previous_home),
        else: System.delete_env("FERMIX_HOME")

      SafeRm.rm_rf!(tmp)
    end)

    %{tmp: tmp, home: home}
  end

  describe "save and load" do
    # The Config round-trips rule: seeded with the shapes application
    # environment holds, which is what setup saves.
    test "every machine setting round-trips through machine.toml, and none through config.toml",
         ctx do
      projects = Path.join(ctx.tmp, "Projects")

      sandbox =
        SandboxConfig.normalize(
          mode: :strict,
          allowed_roots: [projects],
          env: [allow: ["INVENTED_TOKEN"]],
          commands: [profile: :assistant, presets: ["git"]]
        )

      computer_use =
        [enabled: true, courtesy: :off]
        |> ComputerUseConfig.normalize()
        |> ComputerUseConfig.to_keyword()

      computer_history =
        ComputerHistoryConfig.normalize(
          enabled: true,
          apps: ["com.apple.Safari"],
          summarizer: "default",
          remote_summaries: ["anthropic"]
        )

      imessage = [
        enabled: true,
        owner_user_id: "+15550100231",
        allowed_sender_ids: ["+15550100232"]
      ]

      snapshot = %{
        fermix_core: [
          agent: [name: "Orchard"],
          computer_use: computer_use,
          computer_history: computer_history,
          plugins: [enabled: ["invented-notes"], dev_local: Path.join(ctx.tmp, "dev-plugins")]
        ],
        sandbox: sandbox,
        fermix_channels: [imessage: imessage, accessories: [enabled: true]],
        fermix_web: []
      }

      assert :ok = ConfigStore.save_snapshot(snapshot)

      config = File.read!(Path.join(ctx.home, "config.toml"))
      machine = File.read!(MachineFile.path(ctx.home))

      assert ConfigText.value(config, "fermix_core.agent", "name") == {:ok, ~s("Orchard")}

      assert ConfigText.value(config, "fermix_core.plugins", "enabled") ==
               {:ok, ~s(["invented-notes"])}

      assert MachineFile.strip(config) == {config, []}

      assert ConfigText.value(machine, "sandbox", "mode") == {:ok, ~s("strict")}

      assert ConfigText.value(machine, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("default")}

      assert ConfigText.value(machine, "fermix_channels.imessage", "enabled") == {:ok, "true"}
      assert ConfigText.value(machine, "fermix_channels.accessories", "enabled") == {:ok, "true"}
      assert ConfigText.value(machine, "fermix_core.plugins", "dev_local") != :absent
      refute machine =~ "Orchard"
      refute machine =~ "invented-notes"
      assert File.stat!(MachineFile.path(ctx.home)).mode |> Bitwise.band(0o777) == 0o600

      assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false, macos?: true)

      assert loaded.sandbox == sandbox
      assert Keyword.fetch!(loaded.fermix_core, :computer_use) == computer_use
      assert Keyword.fetch!(loaded.fermix_core, :computer_history) == computer_history

      assert Keyword.fetch!(loaded.fermix_core, :plugins)[:dev_local] ==
               Path.join(ctx.tmp, "dev-plugins")

      assert Keyword.fetch!(loaded.fermix_core, :plugins)[:enabled] == ["invented-notes"]
      assert Keyword.fetch!(loaded.fermix_channels, :imessage) == imessage
      assert Keyword.fetch!(loaded.fermix_channels, :accessories) == [enabled: true]

      # And again: a save of what was loaded writes the same two files.
      assert :ok = ConfigStore.save_snapshot(loaded)
      assert File.read!(MachineFile.path(ctx.home)) == machine
      assert File.read!(Path.join(ctx.home, "config.toml")) == config
    end

    # Rule 12: one place per setting. A machine section left in config.toml is
    # read by nothing; an iMessage switch there would refuse the load off a Mac.
    test "a machine setting in config.toml is never read", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @old_config)
      File.write!(MachineFile.path(ctx.home), ~s([sandbox]\nmode = "standard"\n))

      assert {:ok, loaded} =
               ConfigStore.load_runtime_config(resolve_secrets: false, macos?: false)

      assert loaded.sandbox.mode == :standard
      assert loaded.sandbox.allowed_roots == []
      assert Keyword.fetch!(loaded.fermix_channels, :imessage) == []
      assert Keyword.fetch!(loaded.fermix_core, :computer_use)[:enabled] == false
      refute Keyword.has_key?(Keyword.fetch!(loaded.fermix_core, :plugins), :dev_local)
      assert Keyword.fetch!(loaded.fermix_core, :agent)[:name] == "Orchard"
    end
  end

  describe "the boot's migration" do
    test "moves a computer's own settings into machine.toml, and a second boot changes nothing",
         ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @old_config)

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)

      machine = File.read!(MachineFile.path(ctx.home))
      config = File.read!(Path.join(ctx.home, "config.toml"))

      assert machine == MachineFile.extract(@old_config)
      assert machine =~ "# this Mac's own\nmode = \"strict\""
      assert config == elem(MachineFile.strip(@old_config), 0)
      refute File.exists?(MachineFile.path(ctx.home) <> ".tmp")
      refute File.exists?(Path.join(ctx.home, "config.toml.tmp"))

      assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false, macos?: true)
      assert loaded.sandbox.mode == :strict
      assert Keyword.fetch!(loaded.fermix_channels, :imessage)[:enabled] == true
      assert Keyword.fetch!(loaded.fermix_core, :agent)[:name] == "Orchard"

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)
      assert File.read!(MachineFile.path(ctx.home)) == machine
      assert File.read!(Path.join(ctx.home, "config.toml")) == config
    end

    # Interrupted between the two writes: both files hold the settings. The
    # machine file wins, since it was written first.
    test "a boot stopped after the machine file was written finishes the removal", ctx do
      own = MachineFile.header() <> "\n\n[sandbox]\nmode = \"standard\"\n"
      File.write!(Path.join(ctx.home, "config.toml"), @old_config)
      File.write!(MachineFile.path(ctx.home), own)
      # Or stopped inside the second write: its temporary file is written again.
      File.write!(Path.join(ctx.home, "config.toml.tmp"), "[fermix_core.agent]\nna")

      log =
        capture_log(fn ->
          assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)
        end)

      assert log =~ "machine.toml already holds"
      assert File.read!(MachineFile.path(ctx.home)) == own
      refute File.exists?(Path.join(ctx.home, "config.toml.tmp"))

      assert File.read!(Path.join(ctx.home, "config.toml")) ==
               elem(MachineFile.strip(@old_config), 0)

      assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false, macos?: true)
      assert loaded.sandbox.mode == :standard
    end

    # Interrupted inside the first write: only its temporary file is there.
    test "a boot stopped while writing the machine file writes it again", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @old_config)
      File.write!(MachineFile.path(ctx.home) <> ".tmp", "[sandbox]\nmo")

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)

      assert File.read!(MachineFile.path(ctx.home)) == MachineFile.extract(@old_config)
      refute File.exists?(MachineFile.path(ctx.home) <> ".tmp")

      assert File.read!(Path.join(ctx.home, "config.toml")) ==
               elem(MachineFile.strip(@old_config), 0)
    end

    # The machine file is written before config.toml loses anything, so a
    # first write that fails (here its temporary file is a folder) leaves the
    # settings where they were.
    test "a machine file that cannot be written leaves config.toml as it was", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @old_config)
      File.mkdir!(MachineFile.path(ctx.home) <> ".tmp")

      assert {:error, {:file, _path, _reason}} =
               ConfigStore.migrate_machine_file(ctx.home, server?: false)

      assert File.read!(Path.join(ctx.home, "config.toml")) == @old_config
      refute File.exists?(MachineFile.path(ctx.home))
    end

    test "the boot runs it before it reads a setting", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @old_config)

      assert :ok =
               ConfigStore.bootstrap_runtime_config(
                 supervised: false,
                 macos?: true,
                 server?: false
               )

      assert SandboxConfig.current().mode == :strict
      assert File.read!(MachineFile.path(ctx.home)) == MachineFile.extract(@old_config)
    end
  end

  describe "a machine with no machine file" do
    # Fresh machines, the platform injected, never read from the host.
    test "a Mac and a Linux desktop take the shipped defaults and write nothing", ctx do
      for {name, macos?} <- [{"Mac", true}, {"Linux desktop", false}] do
        assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false), name
        assert File.ls!(ctx.home) == [], name

        assert {:ok, loaded} =
                 ConfigStore.load_runtime_config(resolve_secrets: false, macos?: macos?)

        assert loaded.sandbox.mode == :standard, name
        assert loaded.sandbox.allowed_roots == [], name
        assert Keyword.fetch!(loaded.fermix_channels, :imessage) == [], name
        assert Keyword.fetch!(loaded.fermix_channels, :accessories) == [], name
        assert Keyword.fetch!(loaded.fermix_core, :computer_use) == [], name
      end
    end

    test "an Always On server takes its own default, open, written where the owner sees it",
         ctx do
      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: true)

      assert File.read!(MachineFile.path(ctx.home)) == MachineFile.server_default()
      refute File.exists?(Path.join(ctx.home, "config.toml"))

      assert {:ok, loaded} =
               ConfigStore.load_runtime_config(resolve_secrets: false, macos?: false)

      assert loaded.sandbox.mode == MachineFile.server_sandbox_mode()
      assert loaded.sandbox.mode == :open
    end

    # `device/server.json`, written by `fermix home enroll`, is the fact.
    test "a machine marked an Always On server is one, with nothing injected", ctx do
      File.mkdir!(Path.join(ctx.home, "device"))
      File.write!(Candidate.server_path(ctx.home), "{}")

      assert :ok = ConfigStore.migrate_machine_file(ctx.home)
      assert File.read!(MachineFile.path(ctx.home)) == MachineFile.server_default()
    end

    test "a home that is not there yet has nothing to move, and is not made", ctx do
      missing = Path.join(ctx.tmp, "no-home")

      assert :ok = ConfigStore.migrate_machine_file(missing, server?: true)
      refute File.exists?(missing)
    end
  end

  # M75's servers moved before this change: their config.toml holds the Mac's
  # sandbox, folders and switches.
  test "a server that moved leaves out what it inherited, takes open, and says so once", ctx do
    File.write!(Path.join(ctx.home, "config.toml"), @old_config)

    log =
      capture_log(fn ->
        assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: true)
      end)

    assert length(String.split(log, "This server now uses its own sandbox setting: open.")) == 2
    assert log =~ "left out: sandbox, fermix_core.computer_use, fermix_channels.imessage"

    assert File.read!(MachineFile.path(ctx.home)) == MachineFile.server_default()
    config = File.read!(Path.join(ctx.home, "config.toml"))
    assert config == elem(MachineFile.strip(@old_config), 0)
    refute config =~ "/Users/invented"

    # Off a Mac, an inherited iMessage switch would refuse the load.
    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false, macos?: false)
    assert loaded.sandbox.mode == :open
    assert loaded.sandbox.allowed_roots == []
    assert Keyword.fetch!(loaded.fermix_channels, :imessage) == []
    refute Keyword.has_key?(Keyword.fetch!(loaded.fermix_core, :plugins), :dev_local)

    again =
      capture_log(fn ->
        assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: true)
      end)

    refute again =~ "sandbox setting"
  end

  defp restore_env({app, entries}) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(entries, key),
        do: Application.delete_env(app, key)

    for {key, value} <- entries, do: Application.put_env(app, key, value)
  end
end
