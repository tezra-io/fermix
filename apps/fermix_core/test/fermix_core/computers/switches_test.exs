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
      parsed = %{
        "browser" => true,
        "reviewed" => false,
        "enabled" => true,
        "files_and_shell" => false
      }

      assert Switches.normalize(parsed) ==
               [enabled: true, reviewed: false, files_and_shell: false, browser: true]

      assert Switches.normalize(Switches.normalize(parsed)) == Switches.normalize(parsed)
      assert Switches.to_keyword(Switches.normalize(parsed)) == Switches.normalize(parsed)
      assert Switches.normalize(nil) == []
    end

    # M97 D27: one switch for files and commands, none for history (its
    # recorder's own setting) and none for what reaches the server from the
    # computer. A key an earlier engine wrote is read once, by the boot's
    # upgrade, and nowhere else.
    test "the switches are the master, the review and five, and nothing else loads" do
      assert Switches.switches() == [
               :files_and_shell,
               :browser,
               :computer_use,
               :imessage,
               :places
             ]

      for gone <- ~w(files shell history voice attachments accessory notifications camera) do
        assert_raise ArgumentError, ~r/unknown key\(s\): #{gone}/, fn ->
          Switches.normalize(%{gone => true})
        end
      end

      assert_raise ArgumentError, ~r/files_and_shell takes true or false/, fn ->
        Switches.normalize(%{"files_and_shell" => "yes"})
      end
    end

    test "one switch decides files and commands; an offer needs the master on and reviewed" do
      on = Switches.only([:files_and_shell])

      assert Switches.decides(:files_and_shell) == [:files, :shell]
      assert Switches.on?(on, :files)
      assert Switches.on?(on, :shell)
      refute Switches.on?(on, :browser)
      refute Switches.on?(Switches.only([:browser]), :files)
      refute Switches.on?(Switches.only([:browser]), :shell)
      refute Switches.on?(Keyword.put(on, :enabled, false), :shell)
      refute Switches.on?(Keyword.put(on, :reviewed, false), :files)

      # No section: nothing is offered, and nothing waits for a review.
      refute Switches.on?([], :files)
      assert Switches.enabled?([])
      assert Switches.reviewed?([])
      assert Switches.switched_on(on) == [:files_and_shell]
    end

    # Computer history has no switch: its recorder's setting is its consent,
    # under the master and the review, the one rule its every reader follows.
    test "history is offered only with its recorder on, the master on and reviewed" do
      assert Switches.history_on?(Switches.only([]), true)
      refute Switches.history_on?(Switches.only([]), false)
      refute Switches.history_on?(Switches.only([:files_and_shell], enabled: false), true)
      refute Switches.history_on?(Switches.only([:files_and_shell], reviewed: false), true)
      assert_raise FunctionClauseError, fn -> Switches.on?(Switches.only([]), :history) end
    end

    # M89 D13: Apple Maps (`places`) has a switch of its own, like the
    # browser's, decided at each computer. Where nothing is stored it is on,
    # the one default line; the master off or a review in wait keeps it off.
    test "Apple Maps has its own switch, on where nothing is stored, under the master and the review" do
      assert Switches.decides(:places) == [:places]
      assert Switches.default(:places)
      refute Switches.default(:browser)

      # Nothing stored: a section with no `places` key, and no section at all.
      assert Switches.on?([], :places)
      assert Switches.on?([enabled: true, reviewed: true, files_and_shell: true], :places)
      assert :places in Switches.switched_on([])

      # Its own key, off and on again, deciding Apple Maps alone.
      off = Keyword.put(Switches.only(Switches.switches()), :places, false)
      refute Switches.on?(off, :places)
      assert Switches.on?(off, :browser)
      assert Switches.on?(Keyword.put(off, :places, true), :places)
      refute Switches.on?(Switches.only([]), :places)
      assert Switches.on?(Switches.only([:places]), :places)
      refute Switches.on?(Switches.only([:places]), :browser)

      # The master off, or a review in wait, is off, stored or not.
      for flags <- [[enabled: false], [reviewed: false]] do
        refute Switches.on?(flags, :places)
        refute Switches.on?(Switches.only([:places], flags), :places)
      end

      assert Switches.normalize(%{"places" => false}) == [places: false]

      assert_raise ArgumentError, ~r/places takes true or false/, fn ->
        Switches.normalize(%{"places" => "on"})
      end
    end

    test "only names switches, never an offer" do
      for offer <- [:files, :shell, :history, :voice] do
        assert_raise ArgumentError, ~r/#{offer} is no switch/, fn -> Switches.only([offer]) end
      end
    end
  end

  # M97 D27: a section an engine before D27 wrote, read once at the boot's
  # machine-file migration and rewritten; nothing else reads its keys.
  describe "a section an earlier engine wrote" do
    test "files and commands are on only where both were" do
      for {files, shell, merged} <- [
            {"true", "true", "true"},
            {"true", "false", "false"},
            {"false", "true", "false"},
            {"false", "false", "false"},
            {"true", nil, "false"},
            {nil, nil, "false"}
          ] do
        lines =
          ["enabled = true", "reviewed = true", "browser = true"] ++
            for({key, value} <- [files: files, shell: shell], value, do: "#{key} = #{value}") ++
            ["voice = false"]

        {value, machine, notice} = upgraded(computer_table(lines, :absent))
        assert value == {:ok, merged}, inspect({files, shell})
        assert notice =~ "files_and_shell = #{merged}"

        for gone <- ~w(files shell voice) do
          assert ConfigText.value(machine, "fermix_core.computer", gone) == :absent
        end

        assert ConfigText.value(machine, "fermix_core.computer", "browser") == {:ok, "true"}
        assert Switches.upgrade(machine, true) == %{machine: nil, notice: nil}
      end
    end

    test "the master and the review are carried as they were", ctx do
      text =
        computer_table(
          ["enabled = false", "reviewed = false", "files = true", "shell = true"],
          :absent
        )

      {{:ok, "true"}, machine, _notice} = upgraded(text)
      other = Path.join(ctx.tmp, "carried")
      File.mkdir!(other)
      File.write!(MachineFile.path(other), machine)

      assert {:ok, [enabled: false, reviewed: false, files_and_shell: true]} =
               Switches.read(other)
    end

    # HS-5: before D27 a linked computer's server took its history only with
    # its `history` switch on, whatever its recorder did. The upgrade keeps
    # that, as it keeps files and commands: where the old switch was off (or,
    # the switches reviewed, absent) and the recorder is on, the recorder goes
    # off in the same write, said once in words the owner can act on. A
    # review that still waits decides an absent one itself; a recorder that
    # was off stays off; and a Mac that is its own home keeps recording.
    test "on a linked computer, history the server did not take stays out of its reach" do
      recorder = fn machine ->
        ConfigText.value(machine, "fermix_core.computer_history", "enabled")
      end

      for {lines, recorded, stays} <- [
            {["history = false"], true, "false"},
            {["files = true", "shell = true"], true, "false"},
            {["reviewed = true", "files = true"], true, "false"},
            {["reviewed = false", "history = false"], true, "false"},
            {["reviewed = false", "files = true"], true, "true"},
            {["history = true"], true, "true"},
            {["history = true"], false, "false"}
          ] do
        {_merged, machine, notice} = upgraded(computer_table(lines, recorded))
        seen = inspect({lines, recorded})
        assert ConfigText.value(machine, "fermix_core.computer", "history") == :absent, seen
        assert recorder.(machine) == {:ok, stays}, seen

        if recorded and stays == "false",
          do: assert(notice =~ "Turn Computer history on at this computer", seen)
      end

      {_merged, _machine, notice} = upgraded(computer_table(["history = true"], true))
      refute notice =~ "Computer history"

      # Only a linked computer: a Mac that is its own home keeps recording.
      for lines <- [["history = false"], ["files = true", "shell = true"]] do
        {_merged, machine, notice} = upgraded(computer_table(lines, true), false)
        assert recorder.(machine) == {:ok, "true"}
        refute notice =~ "Computer history"
      end
    end

    test "a section that names the merged switch keeps it, and loses what sits beside it" do
      text =
        computer_table(
          ["files_and_shell = true", "files = false", "notifications = false"],
          :absent
        )

      {value, machine, _notice} = upgraded(text)

      assert value == {:ok, "true"}
      assert ConfigText.value(machine, "fermix_core.computer", "files") == :absent
      assert ConfigText.value(machine, "fermix_core.computer", "notifications") == :absent
    end

    test "nothing to upgrade, no file, or a value that is no boolean" do
      assert Switches.upgrade(:absent, true) == %{machine: nil, notice: nil}

      assert Switches.upgrade(computer_table(["files_and_shell = true"], :absent), true) == %{
               machine: nil,
               notice: nil
             }

      assert Switches.upgrade(MachineFile.header() <> "\n", true) == %{machine: nil, notice: nil}

      assert {:error, sentence} =
               Switches.upgrade(computer_table(["files = \"maybe\""], :absent), true)

      assert sentence =~ "files takes true or false"
    end
  end

  describe "save and load" do
    # The Config round-trips rule: seeded with the shape application
    # environment holds, which is what a settings save writes.
    test "the section round-trips through machine.toml, and never through config.toml", ctx do
      computer = Switches.normalize(Switches.only([:files_and_shell, :browser]))

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
      assert ConfigText.value(machine, "fermix_core.computer", "files_and_shell") == {:ok, "true"}
      assert ConfigText.value(machine, "fermix_core.computer", "imessage") == {:ok, "false"}
      assert ConfigText.value(machine, "fermix_core.computer", "history") == :absent

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
      assert :ok = Switches.write(other, Switches.only([:files_and_shell]))

      text = File.read!(MachineFile.path(other))
      assert text =~ "# kept\n[sandbox]\nmode = \"strict\"\n"
      assert {:ok, read} = Switches.read(other)
      assert Keyword.fetch!(read, :files_and_shell)
      refute Keyword.fetch!(read, :imessage)
      assert length(read) == length(Switches.switches()) + 2
      assert File.stat!(MachineFile.path(other)).mode |> Bitwise.band(0o777) == 0o600

      # Another home's write never reaches this engine's environment.
      assert Switches.current() == Application.get_env(:fermix_core, :computer, [])
      refute Switches.on?(Switches.current(), :files)
    end

    test "a home with no machine file gets one with its header", ctx do
      other = Path.join(ctx.tmp, "bare")
      File.mkdir!(other)

      assert :ok = Switches.write(other, Switches.only([:files_and_shell]))
      assert File.read!(MachineFile.path(other)) =~ MachineFile.header()
      assert {:ok, read} = Switches.read(other)
      assert Switches.on?(read, :shell)
    end

    # M89 D13: the owner switches Apple Maps off, and on again, for this
    # computer alone, at this computer; nothing else changes.
    test "the settings door switches Apple Maps off and on again for this computer", ctx do
      Application.put_env(:fermix_core, :computer, Switches.only([:files_and_shell, :places]))
      server = :"restart_state_absent_#{System.unique_integer([:positive])}"
      other = Path.join(ctx.tmp, "other-computer")
      File.mkdir!(other)
      :ok = Switches.write(other, Switches.only([:places]))

      assert {:ok, %{}} = Switches.save([places: false], home: ctx.home, restart_state: server)
      assert {:ok, saved} = Switches.read(ctx.home)
      refute Switches.on?(saved, :places)
      assert Switches.on?(saved, :files)
      refute Switches.on?(Switches.current(), :places)

      assert {:ok, %{}} = Switches.save([places: true], home: ctx.home, restart_state: server)
      assert {:ok, saved} = Switches.read(ctx.home)
      assert Switches.on?(saved, :places)
      assert Switches.on?(saved, :files)

      # Another computer's switch is its own.
      assert {:ok, theirs} = Switches.read(other)
      assert Switches.on?(theirs, :places)
    end

    # A section written before Apple Maps had a switch has no `places` key; a
    # save of another switch writes it at its default, never off.
    test "saving another switch on a section with no places key writes it at its default", ctx do
      File.write!(
        MachineFile.path(ctx.home),
        MachineFile.header() <>
          "\n\n[fermix_core.computer]\nenabled = true\nreviewed = true\nfiles_and_shell = true\n"
      )

      {:ok, stored} = Switches.read(ctx.home)
      refute Keyword.has_key?(stored, :places)
      Application.put_env(:fermix_core, :computer, stored)
      server = :"restart_state_absent_#{System.unique_integer([:positive])}"

      assert {:ok, %{}} = Switches.save([browser: true], home: ctx.home, restart_state: server)
      assert {:ok, saved} = Switches.read(ctx.home)
      assert Keyword.fetch!(saved, :places) == Switches.default(:places)
      assert Switches.on?(saved, :places)
      assert Switches.on?(saved, :browser) and Switches.on?(saved, :files)
    end

    test "a write to the running home is applied at once and tells the reporter", ctx do
      Process.register(self(), Switches.listener())

      assert :ok = Switches.write(ctx.home, Switches.only([:browser]))
      assert Switches.on?(Switches.current(), :browser)
      assert_receive {:"$gen_cast", :switches_changed}
    end

    test "the settings door's save is a review, and never writes the review itself", ctx do
      Application.put_env(:fermix_core, :computer, Switches.only([], reviewed: false))
      server = :"restart_state_absent_#{System.unique_integer([:positive])}"

      assert {:ok, %{}} =
               Switches.save([files_and_shell: true], home: ctx.home, restart_state: server)

      assert Switches.reviewed?(Switches.current())
      assert Switches.on?(Switches.current(), :files)
      assert Switches.on?(Switches.current(), :shell)

      # The review has no row: it is this computer's state, written by a review.
      assert_raise ArgumentError, ~r/reviewed/, fn ->
        Switches.save([reviewed: true], home: ctx.home, restart_state: server)
      end
    end
  end

  defp computer_table(lines, recorder) do
    history =
      if recorder == :absent,
        do: "",
        else: "[fermix_core.computer_history]\nenabled = #{recorder}\n\n"

    MachineFile.header() <>
      "\n\n" <> history <> "[fermix_core.computer]\n" <> Enum.join(lines, "\n") <> "\n"
  end

  defp upgraded(text, linked? \\ true) do
    assert %{machine: machine, notice: {level, notice}} = Switches.upgrade(text, linked?)
    assert is_binary(machine) and is_binary(notice) and level in [:info, :warning]
    {ConfigText.value(machine, "fermix_core.computer", "files_and_shell"), machine, notice}
  end

  defp restore_env({app, entries}) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(entries, key),
        do: Application.delete_env(app, key)

    for {key, value} <- entries, do: Application.put_env(app, key, value)
  end
end
