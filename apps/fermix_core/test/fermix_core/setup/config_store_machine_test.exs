defmodule FermixCore.Setup.ConfigStoreMachineTest do
  # M97 §4: this computer's own settings live in `machine.toml`, beside
  # `config.toml`. async: false, since the store reads FERMIX_HOME from the
  # environment, and the boot test applies application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory.Config, as: ComputerHistoryConfig
  alias FermixCore.ComputerUse.Config, as: ComputerUseConfig
  alias FermixCore.Harness.Config, as: HarnessConfig
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

      # Application environment's own shapes: this machine's local summarizer
      # beside the home's route (M97 §4).
      computer_history =
        ComputerHistoryConfig.normalize(
          enabled: true,
          apps: ["com.apple.Safari"],
          machine_summarizer: :local,
          summarizer: :default_provider,
          remote_summaries: [:anthropic]
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

      # Computer history splits by key: this machine records, its apps and
      # its own notes here; the home's route and grants in config.toml.
      assert ConfigText.value(machine, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("local")}

      assert ConfigText.value(machine, "fermix_core.computer_history", "apps") ==
               {:ok, ~s(["com.apple.Safari"])}

      refute machine =~ "remote_summaries"

      assert ConfigText.value(config, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("default")}

      assert ConfigText.value(config, "fermix_core.computer_history", "remote_summaries") ==
               {:ok, ~s(["anthropic"])}

      refute config =~ "com.apple.Safari"

      # The home uses iMessage, with its owner and guests (M97 §4).
      assert ConfigText.value(config, "fermix_channels.imessage", "enabled") == {:ok, "true"}
      refute machine =~ "imessage"
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
      # The home's own: read from config.toml, on a host that is no Mac too.
      assert Keyword.fetch!(loaded.fermix_channels, :imessage)[:owner_user_id] == "+15550100231"
      assert Keyword.fetch!(loaded.fermix_core, :computer_use)[:enabled] == false
      refute Keyword.has_key?(Keyword.fetch!(loaded.fermix_core, :plugins), :dev_local)
      assert Keyword.fetch!(loaded.fermix_core, :agent)[:name] == "Orchard"
    end

    # Between starts a person may write one into config.toml by hand; nothing
    # reads it there, so a reload names it (`Management.Settings.reload/1`).
    test "names the machine settings config.toml holds, and none where it holds none", ctx do
      assert ConfigStore.misplaced_machine_settings(ctx.home) == {:ok, []}

      File.write!(Path.join(ctx.home, "config.toml"), @old_config)

      assert ConfigStore.misplaced_machine_settings(ctx.home) ==
               {:ok, ~w(sandbox fermix_core.computer_use fermix_core.plugins.dev_local)}

      {home_only, _removed} = MachineFile.strip(@old_config)
      File.write!(Path.join(ctx.home, "config.toml"), home_only)
      assert ConfigStore.misplaced_machine_settings(ctx.home) == {:ok, []}
    end

    # A save writes config.toml from what runs, which never holds those, so
    # it drops them: it says which, in the sentence a start says it with.
    test "a save that drops machine settings from config.toml names them", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @old_config)
      File.write!(MachineFile.path(ctx.home), ~s([sandbox]\nmode = "standard"\n))
      {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false, macos?: false)

      log = capture_log(fn -> assert :ok = ConfigStore.save_snapshot(loaded) end)

      assert log =~
               "config.toml held this computer's own settings, which Fermix reads only from " <>
                 "machine.toml, so they were removed from it: sandbox, " <>
                 "fermix_core.computer_use, fermix_core.plugins.dev_local."

      assert ConfigStore.misplaced_machine_settings(ctx.home) == {:ok, []}

      # The next save finds none there, and says nothing of them.
      refute capture_log(fn -> assert :ok = ConfigStore.save_snapshot(loaded) end) =~
               "own settings"
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

    # M97 stage 0 wrote the iMessage section into machine.toml; it is the
    # home's, so the boot gives it back to config.toml and a server that
    # receives the home knows the owner and guests (§4).
    test "the iMessage section a machine file holds goes back to config.toml, once", ctx do
      {home_only, _removed} = MachineFile.strip(@old_config)
      config_without = ConfigText.drop_tables(home_only, "fermix_channels.imessage")
      File.write!(Path.join(ctx.home, "config.toml"), config_without)

      File.write!(MachineFile.path(ctx.home), """
      [sandbox]
      mode = "standard"

      [fermix_channels.imessage]
      enabled = true
      owner_user_id = "+15550100231"
      allowed_sender_ids = ["+15550100232"]

      [fermix_core.computer]
      imessage = true
      """)

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)

      config = File.read!(Path.join(ctx.home, "config.toml"))
      machine = File.read!(MachineFile.path(ctx.home))

      assert ConfigText.value(config, "fermix_channels.imessage", "owner_user_id") ==
               {:ok, ~s("+15550100231")}

      refute machine =~ "[fermix_channels.imessage]"
      assert ConfigText.value(machine, "fermix_core.computer", "imessage") == {:ok, "true"}

      assert {:ok, loaded} =
               ConfigStore.load_runtime_config(resolve_secrets: false, macos?: false)

      assert Keyword.fetch!(loaded.fermix_channels, :imessage) == [
               enabled: true,
               owner_user_id: "+15550100231",
               allowed_sender_ids: ["+15550100232"]
             ]

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)
      assert File.read!(Path.join(ctx.home, "config.toml")) == config
      assert File.read!(MachineFile.path(ctx.home)) == machine
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

      assert log =~ "which Fermix reads only from machine.toml, so they were removed from it"
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

  # A home the Mac app manages is the app engine's to migrate: another
  # engine pointed at it (a formula binary, a source checkout) moves nothing
  # there, while the app's own first start on a release that reads
  # machine.toml does, and so does any engine on a home the app does not
  # manage. Every home is this test's temporary one.
  describe "who moves a home's settings" do
    test "the app's own engine moves them in the home the app manages", ctx do
      app_manages!(ctx)
      File.write!(Path.join(ctx.home, "config.toml"), @old_config)

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false, app_engine?: true)
      assert File.read!(MachineFile.path(ctx.home)) == MachineFile.extract(@old_config)
    end

    test "another engine refuses by name, and writes nothing there", ctx do
      app_manages!(ctx)
      File.write!(Path.join(ctx.home, "config.toml"), @old_config)

      assert {:error, {:app_managed, home} = reason} =
               ConfigStore.migrate_machine_file(ctx.home, server?: false, app_engine?: false)

      assert home == ctx.home
      assert ConfigStore.load_error_sentence(reason) =~ "#{ctx.home} is managed by Fermix.app"
      assert File.read!(Path.join(ctx.home, "config.toml")) == @old_config
      refute File.exists?(MachineFile.path(ctx.home))
      refute File.exists?(Path.join(ctx.home, "config.toml.lock"))
    end

    test "another engine boots on a home the app already moved, with nothing to move", ctx do
      app_manages!(ctx)
      {home_only, _removed} = MachineFile.strip(@old_config)
      File.write!(Path.join(ctx.home, "config.toml"), home_only)
      File.write!(MachineFile.path(ctx.home), MachineFile.extract(@old_config))

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false, app_engine?: false)
      assert File.read!(Path.join(ctx.home, "config.toml")) == home_only
    end

    test "a home whose app is gone, or that no app manages, is moved by any engine", ctx do
      app_manages!(ctx)
      File.write!(Path.join(ctx.home, "config.toml"), @old_config)

      assert :ok =
               ConfigStore.migrate_machine_file(ctx.home,
                 server?: false,
                 app_engine?: false,
                 bundle_exists?: fn _bundle -> false end
               )

      assert File.read!(MachineFile.path(ctx.home)) == MachineFile.extract(@old_config)

      other = Path.join(ctx.tmp, "dev-home")
      File.mkdir!(other)
      File.write!(Path.join(other, "config.toml"), @old_config)
      assert :ok = ConfigStore.migrate_machine_file(other, server?: false, app_engine?: false)
      assert File.read!(MachineFile.path(other)) == MachineFile.extract(@old_config)
    end

    test "a settings file it cannot read is named", ctx do
      config = Path.join(ctx.home, "config.toml")
      File.write!(config, @old_config)
      File.chmod!(config, 0o000)
      on_exit(fn -> File.chmod(config, 0o600) end)

      assert {:error, {:config, ^config, :eacces} = reason} =
               ConfigStore.migrate_machine_file(ctx.home, server?: false)

      assert ConfigStore.load_error_sentence(reason) ==
               "#{config} could not be read: permission denied."
    end
  end

  # A source checkout (`:dev`) has no default home: with no FERMIX_HOME it
  # refuses before it reads or writes anything; with one, and in every other
  # build, it goes on.
  describe "a source checkout names its home" do
    test "the dev environment needs FERMIX_HOME; a release and the suite do not" do
      for unset <- [nil, ""] do
        assert {:error, sentence} = ConfigStore.source_home(:dev, unset)
        assert sentence =~ "Set FERMIX_HOME to the home it should use"
      end

      assert :ok = ConfigStore.source_home(:dev, "/tmp/fermix-dev-home-invented")
      assert :ok = ConfigStore.source_home(:prod, nil)
      assert :ok = ConfigStore.source_home(:test, nil)
    end

    # In a VM of its own, as a `mix` command starts one, with no FERMIX_HOME:
    # this suite's VM keeps its own home throughout, so nothing here can fall
    # back to the installed one.
    test "the configuration a dev command loads refuses before it reads a home" do
      runtime = Path.expand("../../../../../config/runtime.exs", __DIR__)
      script = "Config.Reader.read!(#{inspect(runtime)}, env: :dev, target: :host)"

      {output, status} =
        System.cmd(
          System.find_executable("elixir"),
          ["-pa", Application.app_dir(:fermix_core, "ebin"), "-e", script],
          env: [{"FERMIX_HOME", nil}],
          stderr_to_stdout: true
        )

      refute status == 0
      assert output =~ "this is a Fermix source checkout, which never uses the installed home"
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
    assert log =~ "left out: sandbox, fermix_core.computer_use, fermix_core.plugins.dev_local"
    # The home uses iMessage, and its server knows the owner (M97 §4).
    refute log =~ "fermix_channels.imessage"

    assert File.read!(MachineFile.path(ctx.home)) == MachineFile.server_default()
    config = File.read!(Path.join(ctx.home, "config.toml"))
    assert config == elem(MachineFile.strip(@old_config), 0)
    refute config =~ "/Users/invented"

    # The server knows who the owner is: the Mac that carries Messages runs
    # the helper (M97 §4, §6.4).
    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false, macos?: false)
    assert loaded.sandbox.mode == :open
    assert loaded.sandbox.allowed_roots == []

    assert Keyword.fetch!(loaded.fermix_channels, :imessage) ==
             [enabled: true, owner_user_id: "+15550100231"]

    refute Keyword.has_key?(Keyword.fetch!(loaded.fermix_core, :plugins), :dev_local)

    again =
      capture_log(fn ->
        assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: true)
      end)

    refute again =~ "sandbox setting"
  end

  # M97 §4: [fermix_core.computer_history] splits by key. This machine's file
  # keeps whether it records, its apps and `summarizer = "local"`; the home's
  # config.toml keeps the route the home summarizes on and its grants.
  describe "computer history split by key" do
    # A released engine kept the whole table in config.toml; this Mac is its
    # own home and chose local.
    @released_history """
    [fermix_core.agent]
    name = "Orchard"

    [fermix_core.computer_history]
    enabled = true
    apps = ["com.example.Notes"]
    summarizer = "local"
    remote_summaries = ["anthropic"]
    """

    # Stage 0 of M97 kept the whole table in machine.toml.
    @stage0_machine """
    [sandbox]
    mode = "standard"

    [fermix_core.computer_history]
    enabled = true
    apps = ["com.example.Notes"]
    summarizer = "anthropic"
    remote_summaries = ["anthropic"]
    """

    test "a Mac that is its own home and chose local stays local, sittings and roll-up", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @released_history)

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)
      history = loaded_history()

      assert history[:machine_summarizer] == :local
      assert history[:summarizer] == :local
      assert history[:enabled] == true
      assert history[:remote_summaries] == [:anthropic]
      # The one reader every half asks: the sittings and the roll-up alike.
      assert ComputerHistoryConfig.summarizer(history) == :local

      config = File.read!(Path.join(ctx.home, "config.toml"))
      refute config =~ "com.example.Notes"
      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)
      assert File.read!(Path.join(ctx.home, "config.toml")) == config
    end

    # Interrupted after the machine file was written: config.toml still holds
    # the Mac's keys; the next boot finishes the removal and loses nothing.
    test "a release boot stopped after its first write is finished by the next", ctx do
      plan = MachineFile.migration(@released_history, :absent, false)
      File.write!(Path.join(ctx.home, "config.toml"), @released_history)
      File.write!(MachineFile.path(ctx.home), plan.machine)

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)

      assert File.read!(Path.join(ctx.home, "config.toml")) == plan.config
      assert File.read!(MachineFile.path(ctx.home)) == plan.machine
      assert ComputerHistoryConfig.summarizer(loaded_history()) == :local
      assert loaded_history()[:apps] == ["com.example.Notes"]
    end

    test "a server keeps the home's keys and never takes the computer's", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @released_history)

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: true)

      assert File.read!(MachineFile.path(ctx.home)) == MachineFile.server_default()
      history = loaded_history()

      assert history[:summarizer] == :local
      assert history[:remote_summaries] == [:anthropic]
      refute Keyword.has_key?(history, :machine_summarizer)
      refute Keyword.has_key?(history, :enabled)
      refute Keyword.has_key?(history, :apps)
    end

    test "stage 0's whole table: the home's keys go back to config.toml, once", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), ~s([fermix_core.agent]\nname = "Orchard"\n))
      File.write!(MachineFile.path(ctx.home), @stage0_machine)

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)

      config = File.read!(Path.join(ctx.home, "config.toml"))
      machine = File.read!(MachineFile.path(ctx.home))

      assert ConfigText.value(config, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("anthropic")}

      refute machine =~ "summarizer"
      refute machine =~ "remote_summaries"
      assert loaded_history() == stage0_loaded()

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)
      assert File.read!(Path.join(ctx.home, "config.toml")) == config
      assert File.read!(MachineFile.path(ctx.home)) == machine
    end

    # Interrupted after config.toml took the home's keys: the machine file
    # still holds them; the next boot writes the same config.toml and then
    # the machine file.
    test "a stage 0 boot stopped after its first write is finished by the next", ctx do
      plan = MachineFile.homeward("", @stage0_machine)
      File.write!(Path.join(ctx.home, "config.toml"), plan.config)
      File.write!(MachineFile.path(ctx.home), @stage0_machine)

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)

      assert File.read!(Path.join(ctx.home, "config.toml")) == plan.config
      assert File.read!(MachineFile.path(ctx.home)) == plan.machine
      assert loaded_history() == stage0_loaded()
    end

    # A computer runs nothing that reads the home's keys, and never acts on
    # one its config.toml still carries from before its move.
    test "a computer's application environment holds no home key", ctx do
      File.write!(
        Path.join(ctx.home, "config.toml"),
        ~s([fermix_core.engine]\nrole = "device"\n\n) <> @released_history
      )

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)
      assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
      :ok = ConfigStore.apply_snapshot(loaded, supervised: false)

      history = Application.get_env(:fermix_core, :computer_history)
      assert history[:machine_summarizer] == :local
      refute Keyword.has_key?(history, :summarizer)
      refute Keyword.has_key?(history, :remote_summaries)
      assert ComputerHistoryConfig.granted_providers() == MapSet.new()
    end
  end

  # M98 D5: whether coding agents may run here, and where Codex and Claude
  # Code keep their sign-ins, are this computer's own; the rest of
  # `[fermix_core.harness]`, the default agent among it, is the home's.
  describe "the coding agents' machine keys" do
    # A home a released engine wrote: the whole table in config.toml.
    @released_harness """
    [fermix_core.agent]
    name = "Orchard"

    [fermix_core.harness]
    approved = true
    default_vendor = "claude"
    codex_home = "/Users/invented/.codex-work"
    """

    # An earlier engine of M97 moved the other machine settings already, and
    # wrote a machine file without the table.
    @m97_machine MachineFile.header() <> "\n\n[sandbox]\nmode = \"standard\"\n"

    # The Config round-trips rule: seeded with the shapes application
    # environment holds, which is what setup saves.
    test "save then load: the approval and folders through machine.toml only, the rest through config.toml",
         ctx do
      harness =
        HarnessConfig.normalize(
          enabled: true,
          approved: true,
          default_vendor: "claude",
          max_active: 3,
          codex_home: Path.join(ctx.tmp, "codex"),
          claude_config_dir: Path.join(ctx.tmp, "claude")
        )

      snapshot = %{
        fermix_core: [agent: [name: "Orchard"], harness: harness],
        fermix_channels: [],
        fermix_web: []
      }

      assert :ok = ConfigStore.save_snapshot(snapshot)

      config = File.read!(Path.join(ctx.home, "config.toml"))
      machine = File.read!(MachineFile.path(ctx.home))

      assert ConfigText.value(config, "fermix_core.harness", "default_vendor") ==
               {:ok, ~s("claude")}

      assert ConfigText.value(config, "fermix_core.harness", "max_active") == {:ok, "3"}
      assert MachineFile.strip(config) == {config, []}
      assert ConfigText.value(machine, "fermix_core.harness", "approved") == {:ok, "true"}

      assert ConfigText.value(machine, "fermix_core.harness", "codex_home") ==
               {:ok, inspect(Path.join(ctx.tmp, "codex"))}

      assert ConfigText.value(machine, "fermix_core.harness", "claude_config_dir") ==
               {:ok, inspect(Path.join(ctx.tmp, "claude"))}

      refute machine =~ "default_vendor"
      refute machine =~ "max_active"

      assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
      assert Enum.sort(Keyword.fetch!(loaded.fermix_core, :harness)) == Enum.sort(harness)

      # And again: a save of what was loaded writes the same two files.
      assert :ok = ConfigStore.save_snapshot(loaded)
      assert File.read!(MachineFile.path(ctx.home)) == machine
      assert File.read!(Path.join(ctx.home, "config.toml")) == config
    end

    # The marker: a save writes the approval even when it is off.
    test "a save with no approval writes it off, and it loads off", ctx do
      snapshot = %{
        fermix_core: [harness: HarnessConfig.normalize(default_vendor: "codex")],
        fermix_channels: [],
        fermix_web: []
      }

      assert :ok = ConfigStore.save_snapshot(snapshot)

      machine = File.read!(MachineFile.path(ctx.home))
      assert ConfigText.value(machine, "fermix_core.harness", "approved") == {:ok, "false"}

      assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
      assert Keyword.fetch!(loaded.fermix_core, :harness)[:approved] == false
    end

    test "a released engine's home: the boot moves them with the rest, once", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @released_harness)

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)

      machine = File.read!(MachineFile.path(ctx.home))
      config = File.read!(Path.join(ctx.home, "config.toml"))
      assert ConfigText.value(machine, "fermix_core.harness", "approved") == {:ok, "true"}

      assert ConfigText.value(config, "fermix_core.harness", "default_vendor") ==
               {:ok, ~s("claude")}

      refute config =~ "approved"
      refute config =~ "codex-work"
      assert loaded_harness()[:approved] == true
      assert loaded_harness()[:codex_home] == "/Users/invented/.codex-work"

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)
      assert File.read!(MachineFile.path(ctx.home)) == machine
      assert File.read!(Path.join(ctx.home, "config.toml")) == config
    end

    # The trap: without the step, the machine file would win and config.toml
    # would lose the approval and the folder with nothing taking them.
    test "a machine file without the table takes them first, then config.toml loses them", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @released_harness)
      File.write!(MachineFile.path(ctx.home), @m97_machine)

      # Its notice is an info line (`MachineFile.notice/1`, pinned there).
      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)

      machine = File.read!(MachineFile.path(ctx.home))
      assert machine =~ ~s([sandbox]\nmode = "standard")
      assert ConfigText.value(machine, "fermix_core.harness", "approved") == {:ok, "true"}
      refute File.read!(Path.join(ctx.home, "config.toml")) =~ "approved"
      assert loaded_harness()[:approved] == true
      assert loaded_harness()[:codex_home] == "/Users/invented/.codex-work"
      assert loaded_harness()[:default_vendor] == "claude"

      config = File.read!(Path.join(ctx.home, "config.toml"))
      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)
      assert File.read!(MachineFile.path(ctx.home)) == machine
      assert File.read!(Path.join(ctx.home, "config.toml")) == config
    end

    # Stopped after the machine file was written: it holds the table, so the
    # next boot finishes the removal and keeps what the first one took.
    test "a boot stopped after its first write is finished by the next", ctx do
      plan = MachineFile.migration(@released_harness, @m97_machine, false)
      File.write!(Path.join(ctx.home, "config.toml"), @released_harness)
      File.write!(MachineFile.path(ctx.home), plan.machine)

      log =
        capture_log(fn ->
          assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)
        end)

      assert log =~ "so they were removed from it: fermix_core.harness.approved"
      assert File.read!(MachineFile.path(ctx.home)) == plan.machine
      assert File.read!(Path.join(ctx.home, "config.toml")) == plan.config
      assert loaded_harness()[:approved] == true
    end

    # Stopped inside the first write: the old machine file is still there,
    # so the step runs again and loses nothing.
    test "a boot stopped while writing the machine file takes them again", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @released_harness)
      File.write!(MachineFile.path(ctx.home), @m97_machine)
      File.write!(MachineFile.path(ctx.home) <> ".tmp", "[fermix_core.harness]\nappr")

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)

      refute File.exists?(MachineFile.path(ctx.home) <> ".tmp")

      assert File.read!(MachineFile.path(ctx.home)) ==
               MachineFile.migration(@released_harness, @m97_machine, false).machine

      assert loaded_harness()[:approved] == true
    end

    # With the table the machine file wins: a copy written into config.toml
    # by hand is dropped and named, never read.
    test "a machine file with the table wins over config.toml's copy", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @released_harness)

      File.write!(
        MachineFile.path(ctx.home),
        @m97_machine <> "\n[fermix_core.harness]\napproved = false\n"
      )

      assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
      assert Keyword.fetch!(loaded.fermix_core, :harness)[:approved] == false
      refute Keyword.has_key?(Keyword.fetch!(loaded.fermix_core, :harness), :codex_home)

      log =
        capture_log(fn ->
          assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false)
        end)

      assert log =~ "so they were removed from it: fermix_core.harness.approved"
      assert loaded_harness()[:approved] == false
    end

    # M75's servers moved before this change: an approval given there never
    # moves into the server's own default, and the boot says so.
    test "a server with no machine file takes its default, coding agents not approved", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), @released_harness)

      log =
        capture_log(fn ->
          assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: true)
        end)

      assert log =~ "left out: fermix_core.harness.approved, fermix_core.harness.codex_home."
      assert File.read!(MachineFile.path(ctx.home)) == MachineFile.server_default()

      assert ConfigText.value(MachineFile.server_default(), "fermix_core.harness", "approved") ==
               {:ok, "false"}

      assert loaded_harness()[:approved] == false
      assert loaded_harness()[:default_vendor] == "claude"
      refute Keyword.has_key?(loaded_harness(), :codex_home)
    end

    test "a machine file that names a key of the home's refuses the load, naming machine.toml",
         ctx do
      File.write!(
        MachineFile.path(ctx.home),
        "[fermix_core.harness]\napproved = true\ndefault_vendor = \"codex\"\n"
      )

      error =
        assert_raise ArgumentError, fn ->
          ConfigStore.load_runtime_config(resolve_secrets: false)
        end

      assert error.message ==
               "machine.toml [fermix_core.harness] has unknown key(s): default_vendor. It " <>
                 "takes this computer's approved, codex_home and claude_config_dir; the rest " <>
                 "are in config.toml."
    end

    # M97 §7.2: a setup page left open while coding agents were approved
    # elsewhere saves its coding tab, whose form posts the switch it shows
    # (off): the approval it never changed is the file's at the save.
    test "a stale setup page never takes back an approval given elsewhere" do
      base = %{
        fermix_core: [harness: HarnessConfig.normalize(approved: false)],
        fermix_channels: [],
        fermix_web: []
      }

      assert :ok = ConfigStore.save_snapshot(base)
      {:ok, base} = ConfigStore.load_runtime_config(resolve_secrets: false)

      # Elsewhere, since: the app approves coding agents on this computer.
      approved = put_in(base, [:fermix_core, :harness, :approved], true)
      assert :ok = ConfigStore.save_snapshot(approved)

      # The stale page: its form's unticked box clears the key, as the
      # wizard does, beside the preference it did change.
      stale =
        update_in(base, [:fermix_core, :harness], fn harness ->
          harness |> Keyword.delete(:approved) |> Keyword.put(:default_vendor, "codex")
        end)

      assert {:ok, written} = ConfigStore.save_changes(stale, base, supervised: false)
      assert Keyword.fetch!(written.fermix_core, :harness)[:approved] == true
      assert loaded_harness()[:approved] == true
      assert loaded_harness()[:default_vendor] == "codex"
    end

    # A home the Mac app manages is the app engine's to migrate: the step is
    # a write, so another engine refuses it by name; with nothing pending it
    # boots, and nothing adds the table to a machine file at a boot.
    test "on a home the app manages, another engine refuses a pending step and boots without one",
         ctx do
      app_manages!(ctx)
      File.write!(Path.join(ctx.home, "config.toml"), @released_harness)
      File.write!(MachineFile.path(ctx.home), @m97_machine)

      assert {:error, {:app_managed, _home}} =
               ConfigStore.migrate_machine_file(ctx.home, server?: false, app_engine?: false)

      assert File.read!(MachineFile.path(ctx.home)) == @m97_machine
      assert File.read!(Path.join(ctx.home, "config.toml")) == @released_harness

      {home_only, _removed} = MachineFile.strip(@released_harness)
      File.write!(Path.join(ctx.home, "config.toml"), home_only)

      assert :ok = ConfigStore.migrate_machine_file(ctx.home, server?: false, app_engine?: false)
      assert File.read!(MachineFile.path(ctx.home)) == @m97_machine
    end
  end

  defp loaded_harness do
    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    Keyword.fetch!(loaded.fermix_core, :harness)
  end

  defp loaded_history do
    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    Keyword.fetch!(loaded.fermix_core, :computer_history)
  end

  defp stage0_loaded,
    do:
      ComputerHistoryConfig.normalize(
        enabled: true,
        apps: ["com.example.Notes"],
        summarizer: :anthropic,
        remote_summaries: [:anthropic]
      )

  # The home's marker names the Mac app, whose bundle (a folder of this
  # test's) is there.
  defp app_manages!(ctx) do
    bundle = Path.join(ctx.tmp, "Fermix.app")
    File.mkdir_p!(bundle)

    File.write!(
      Path.join(ctx.home, "engine-owner.json"),
      Jason.encode!(%{
        "distribution_identity" => "macos_app",
        "product_version" => "0.18.0",
        "build_id" => "orchard-build-7",
        "app_bundle_path" => bundle,
        "written_at" => "2026-11-02T08:15:00Z"
      })
    )
  end

  defp restore_env({app, entries}) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(entries, key),
        do: Application.delete_env(app, key)

    for {key, value} <- entries, do: Application.put_env(app, key, value)
  end
end
