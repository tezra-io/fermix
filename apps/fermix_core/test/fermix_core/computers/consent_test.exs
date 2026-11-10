defmodule FermixCore.Computers.ConsentTest do
  # M97 §7.3 (O3): what a computer keeps on for its server after a move, and
  # the review of a computer that moved before M97.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Consent
  alias FermixCore.Computers.Switches
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

  test "a move keeps files, commands and the browser, and what was on before", %{home: home} do
    opts = [snapshot: @mac_snapshot, os: :macos]

    assert Consent.default_keep(opts) == [:files, :shell, :browser, :computer_use, :imessage]

    block = Consent.keep_on_block(home, opts)

    assert block.sentence ==
             "After the move, Fermix on your server can still use this Mac for: files, " <>
               "commands (open), the browser, your screen, Messages. Change this here."

    assert block.warning =~ "sandbox open, a server that is taken over can read and change"

    assert Enum.map(block.lines, &{&1.offer, &1.on}) == [
             files: true,
             shell: true,
             browser: true,
             computer_use: true,
             imessage: true,
             history: false
           ]
  end

  test "a Linux computer's block has no Messages and no history, and no warning when strict" do
    block = Consent.block([:files, :shell], os: :linux, sandbox_mode: :strict)

    assert Enum.map(block.lines, & &1.offer) == [:files, :shell, :browser, :computer_use]
    assert block.warning == nil
    assert block.sentence =~ "this computer for: files, commands (strict)."
    assert Consent.block([], os: :linux, sandbox_mode: :strict).sentence =~ "can use nothing"
  end

  test "keep names only the offers a move decides" do
    assert {:ok, [:files, :browser]} = Consent.cast(["files", "browser", "files"])
    assert {:error, "voice"} = Consent.cast(["files", "voice"])
    assert {:error, "camera"} = Consent.cast(["camera"])
  end

  test "a move's decision is written on and reviewed", %{home: home} do
    assert :ok = Consent.accept(home, [:files, :shell])
    assert {:ok, switches} = Switches.read(home)
    assert Switches.on?(switches, :files)
    refute Switches.on?(switches, :browser)
    assert Switches.reviewed?(switches)
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
    assert Consent.proposed(switches) == [:files, :shell, :browser, :computer_use, :imessage]
    # Waiting, it offers nothing.
    refute Switches.on?(switches, :files)

    assert Consent.derive_moved(home, opts) == :unchanged

    assert :ok = Consent.review(home, [:files])
    assert {:ok, reviewed} = Switches.read(home)
    assert Switches.reviewed?(reviewed)
    assert Switches.on?(reviewed, :files)
    refute Switches.on?(reviewed, :shell)
    assert Consent.derive_moved(home, opts) == :unchanged
  end

  test "the block's words are a wire map" do
    view = Consent.view(Consent.block([:files], os: :macos, sandbox_mode: :standard))

    assert %{
             "sentence" => _,
             "warning" => nil,
             "lines" => [%{"offer" => "files", "on" => true} | _]
           } =
             view
  end
end
