defmodule FermixCore.Computers.ConsentTest do
  # M97 §7.3 (O3): what a computer keeps on for its server after a move, and
  # the review of a computer that moved before M97.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Promise
  alias FermixCore.Computers.Consent
  alias FermixCore.Computers.Switches
  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Setup.MachineFile
  alias FermixTestSupport.SafeRm

  # A Mac whose screen and Messages were on, its history off, its sandbox open.
  @mac_snapshot %{
    fermix_core: [computer_use: [enabled: true], computer_history: [enabled: false]],
    fermix_channels: [imessage: [enabled: true]],
    sandbox: [mode: :open]
  }

  setup do
    home = SafeRm.make_tmp_dir!("computer_consent")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "a move keeps files and commands, the browser, and what was on before", %{home: home} do
    opts = [snapshot: @mac_snapshot, os: :macos]

    assert Consent.default_keep(opts) == [:files_and_shell, :browser, :computer_use, :imessage]

    block = Consent.keep_on_block(home, opts)

    assert block.sentence ==
             "After the move, Fermix on your server can still use this Mac for: files and " <>
               "commands (open), the browser, your screen, Messages. Change this here."

    assert block.warning =~ "sandbox open, a server that is taken over can read and change"

    assert Enum.map(block.lines, &{&1.offer, &1.label, &1.on}) == [
             {:files_and_shell, "files and commands", true},
             {:browser, "the browser", true},
             {:computer_use, "your screen", true},
             {:imessage, "Messages", true},
             {:history, "your computer history", false}
           ]
  end

  test "a Linux computer's block has no Messages and no history, and no warning when strict" do
    block = Consent.block([:files_and_shell], os: :linux, sandbox_mode: :strict)

    assert Enum.map(block.lines, & &1.offer) == [:files_and_shell, :browser, :computer_use]
    assert block.warning == nil
    assert block.sentence =~ "this computer for: files and commands (strict)."
    assert Consent.block([], os: :linux, sandbox_mode: :strict).sentence =~ "can use nothing"
  end

  # M97 §8.2: where history stays on, the block restates the promise, from the
  # one function that decides it. After a move the sitting goes to the server,
  # or, where this Mac makes its own notes, only the summary does.
  test "history kept on restates the promise as this Mac will keep it" do
    for local <- [[], [machine_summarizer: "local"]] do
      snapshot = %{fermix_core: [computer_history: [enabled: true] ++ local], sandbox: []}
      block = Consent.block([:history], os: :macos, sandbox_mode: :standard, snapshot: snapshot)
      facts = %{server?: true, local?: local != [], provider: nil, machine: "Mac"}

      assert String.ends_with?(block.sentence, Promise.sentence(:clause, facts))
    end

    local = %{fermix_core: [computer_history: [machine_summarizer: "local"]], sandbox: []}
    block = Consent.block([:history], os: :macos, sandbox_mode: :standard, snapshot: local)
    assert block.sentence =~ "only the summary is sent to your Fermix server"
    # The home's route is the home's: a Mac about to move reads its own choice.
    home_local = %{fermix_core: [computer_history: [summarizer: "local"]], sandbox: []}
    block = Consent.block([:history], os: :macos, sandbox_mode: :standard, snapshot: home_local)
    assert block.sentence =~ "each finished sitting is sent to your Fermix server"
  end

  test "keep names only the lines a move decides, in the block's order" do
    assert {:ok, [:files_and_shell, :browser]} =
             Consent.cast(["browser", "files_and_shell", "browser"])

    assert {:error, "voice"} = Consent.cast(["files_and_shell", "voice"])
    assert {:error, "camera"} = Consent.cast(["camera"])
  end

  # M97 §3.4, D27: what an app or a move request from before D27 sends names
  # files and commands as two lines; the merged switch is on only where both
  # are named, as at the file's upgrade.
  test "an earlier engine's two lines for files and commands are read as one, conservatively" do
    assert {:ok, [:files_and_shell, :history]} = Consent.cast(["history", "shell", "files"])
    assert {:ok, [:browser]} = Consent.cast(["files", "browser"])
    assert {:ok, []} = Consent.cast(["shell"])
    assert {:ok, [:files_and_shell]} = Consent.cast(["files", "files_and_shell"])
    assert Consent.known(["files", "notes", "browser"]) == {[:browser], ["notes"]}
  end

  test "a move's decision is written on and reviewed, the history line deciding the recorder",
       %{home: home} do
    File.write!(MachineFile.path(home), "[fermix_core.computer_history]\nenabled = true\n")

    assert :ok = Consent.accept(home, [:files_and_shell])
    assert {:ok, switches} = Switches.read(home)
    assert Switches.on?(switches, :files) and Switches.on?(switches, :shell)
    refute Switches.on?(switches, :browser)
    assert Switches.reviewed?(switches)
    assert recorder(home) == {:ok, "false"}

    assert :ok = Consent.accept(home, [:browser, :history])
    assert recorder(home) == {:ok, "true"}
    assert {:ok, switches} = Switches.read(home)
    assert Switches.switched_on(switches) == [:browser]
  end

  test "a computer that moved before M97 is derived once, waiting for review", %{home: home} do
    opts = [snapshot: @mac_snapshot, os: :macos]

    # No link: not a computer of a server.
    assert Consent.derive_moved(home, opts) == :unchanged
    refute File.exists?(MachineFile.path(home))

    File.mkdir_p!(Path.dirname(DesktopLink.path(home)))
    File.write!(DesktopLink.path(home), "{}")

    assert {:derived, switches} = Consent.derive_moved(home, opts)
    refute Switches.reviewed?(switches)

    assert Switches.normalize(switches) == [
             enabled: true,
             reviewed: false,
             files_and_shell: true,
             browser: true,
             computer_use: true,
             imessage: true
           ]

    # History is the recorder's own: proposed where it records, never written.
    assert Consent.proposed(switches, opts) ==
             [:files_and_shell, :browser, :computer_use, :imessage]

    recording = put_in(@mac_snapshot, [:fermix_core, :computer_history], enabled: true)
    assert :history in Consent.proposed(switches, snapshot: recording, os: :macos)
    assert recorder(home) == :absent
    # Waiting, it offers nothing.
    refute Switches.on?(switches, :files)

    assert Consent.derive_moved(home, opts) == :unchanged

    assert :ok = Consent.review(home, [:browser])
    assert {:ok, reviewed} = Switches.read(home)
    assert Switches.reviewed?(reviewed)
    assert Switches.on?(reviewed, :browser)
    refute Switches.on?(reviewed, :shell)
    assert Consent.derive_moved(home, opts) == :unchanged
  end

  test "the block's words are a wire map" do
    view = Consent.view(Consent.block([:files_and_shell], os: :macos, sandbox_mode: :standard))

    assert %{
             "sentence" => _,
             "warning" => nil,
             "lines" => [%{"offer" => "files_and_shell", "on" => true} | _]
           } =
             view
  end

  defp recorder(home),
    do:
      home
      |> MachineFile.path()
      |> File.read!()
      |> ConfigText.value("fermix_core.computer_history", "enabled")
end
