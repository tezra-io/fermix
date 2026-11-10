defmodule FermixCore.Computers.SwitchesTest do
  # M97 §7.2: what Fermix on the server may use on this computer, the
  # `[fermix_core.computer]` section of its machine.toml. async: false: the
  # store reads FERMIX_HOME from the environment, and a write to the running
  # home puts application environment.
  use ExUnit.Case, async: false

  alias FermixCore.Computers.Switches
  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.MachineFile
  alias FermixTestSupport.SafeRm

  @apps [:fermix_core, :fermix_channels, :fermix_web]

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_env = for app <- @apps, do: {app, Application.get_all_env(app)}

    FermixTestSupport.SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)

    tmp = SafeRm.make_tmp_dir!("computer-switches")
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

  describe "the section's shape" do
    test "normalize takes the file's strings and its own output, in the section's order" do
      parsed = %{"files" => true, "reviewed" => false, "enabled" => true, "shell" => false}

      assert Switches.normalize(parsed) ==
               [enabled: true, reviewed: false, files: true, shell: false]

      assert Switches.normalize(Switches.normalize(parsed)) == Switches.normalize(parsed)
      assert Switches.to_keyword(Switches.normalize(parsed)) == Switches.normalize(parsed)
      assert Switches.normalize(nil) == []
    end

    test "an unknown key or a value that is not a boolean refuses by name" do
      assert_raise ArgumentError, ~r/unknown key\(s\): camera/, fn ->
        Switches.normalize(%{"camera" => true})
      end

      assert_raise ArgumentError, ~r/files takes true or false/, fn ->
        Switches.normalize(%{"files" => "yes"})
      end
    end

    test "an offer is on only with the master on, reviewed, and its own switch on" do
      on = Switches.only([:files, :shell])

      assert Switches.on?(on, :files)
      assert Switches.on?(on, :shell)
      refute Switches.on?(on, :browser)
      refute Switches.on?(Keyword.put(on, :enabled, false), :files)
      refute Switches.on?(Keyword.put(on, :reviewed, false), :files)

      # No section: nothing is offered, and nothing waits for a review.
      refute Switches.on?([], :files)
      assert Switches.enabled?([])
      assert Switches.reviewed?([])
      assert Switches.switched_on(on) == [:files, :shell]
    end
  end

  describe "save and load" do
    # The Config round-trips rule: seeded with the shape application
    # environment holds, which is what a settings save writes.
    test "the section round-trips through machine.toml, and never through config.toml", ctx do
      computer = Switches.normalize(Switches.only([:files, :shell, :browser]))

      snapshot = %{
        fermix_core: [agent: [name: "Orchard"], computer: computer],
        sandbox: [],
        fermix_channels: [],
        fermix_web: []
      }

      assert :ok = ConfigStore.save_snapshot(snapshot)

      config = File.read!(Path.join(ctx.home, "config.toml"))
      machine = File.read!(MachineFile.path(ctx.home))

      refute config =~ "fermix_core.computer]"
      assert ConfigText.value(machine, "fermix_core.computer", "files") == {:ok, "true"}
      assert ConfigText.value(machine, "fermix_core.computer", "history") == {:ok, "false"}

      assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false, macos?: true)
      assert Keyword.fetch!(loaded.fermix_core, :computer) == computer

      assert :ok = ConfigStore.save_snapshot(loaded)
      assert File.read!(MachineFile.path(ctx.home)) == machine
      assert File.read!(Path.join(ctx.home, "config.toml")) == config
    end

    test "a section the file holds wrong refuses the load by name", ctx do
      File.write!(MachineFile.path(ctx.home), "[fermix_core.computer]\nscreen = true\n")

      assert_raise ArgumentError, ~r/fermix_core.computer\] has unknown key\(s\): screen/, fn ->
        ConfigStore.load_runtime_config(resolve_secrets: false, macos?: true)
      end
    end
  end

  describe "write and read" do
    test "write sets every key and keeps every other line of the file", ctx do
      other = Path.join(ctx.tmp, "other")
      File.mkdir!(other)
      File.write!(MachineFile.path(other), "# kept\n[sandbox]\nmode = \"strict\"\n")

      assert {:ok, []} = Switches.read(other)
      assert :ok = Switches.write(other, Switches.only([:files]))

      text = File.read!(MachineFile.path(other))
      assert text =~ "# kept\n[sandbox]\nmode = \"strict\"\n"
      assert {:ok, read} = Switches.read(other)
      assert Keyword.fetch!(read, :files)
      refute Keyword.fetch!(read, :notifications)
      assert length(read) == length(Switches.offers()) + 2
      assert File.stat!(MachineFile.path(other)).mode |> Bitwise.band(0o777) == 0o600

      # Another home's write never reaches this engine's environment.
      assert Switches.current() == Application.get_env(:fermix_core, :computer, [])
      refute Switches.on?(Switches.current(), :files)
    end

    test "a home with no machine file gets one with its header", ctx do
      other = Path.join(ctx.tmp, "bare")
      File.mkdir!(other)

      assert :ok = Switches.write(other, Switches.only([:shell]))
      assert File.read!(MachineFile.path(other)) =~ MachineFile.header()
      assert {:ok, read} = Switches.read(other)
      assert Switches.on?(read, :shell)
    end

    test "a write to the running home is applied at once and tells the reporter", ctx do
      Process.register(self(), Switches.listener())

      assert :ok = Switches.write(ctx.home, Switches.only([:browser]))
      assert Switches.on?(Switches.current(), :browser)
      assert_receive {:"$gen_cast", :switches_changed}
    end

    test "the settings door's save is a review, and a review is never taken back", ctx do
      Application.put_env(:fermix_core, :computer, Switches.only([], reviewed: false))
      server = :"restart_state_absent_#{System.unique_integer([:positive])}"

      assert {:ok, %{}} = Switches.save([files: true], home: ctx.home, restart_state: server)
      assert Switches.reviewed?(Switches.current())
      assert Switches.on?(Switches.current(), :files)

      assert_raise ArgumentError, ~r/A review cannot be taken back/, fn ->
        Switches.save([reviewed: false], home: ctx.home, restart_state: server)
      end
    end
  end

  defp restore_env({app, entries}) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(entries, key),
        do: Application.delete_env(app, key)

    for {key, value} <- entries, do: Application.put_env(app, key, value)
  end
end
