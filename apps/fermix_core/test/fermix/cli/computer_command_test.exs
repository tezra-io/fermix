defmodule Fermix.CLI.ComputerCommandTest do
  # M97 §3.1: `fermix computer join`, with no engine tree, against a stopped
  # Fermix. The code comes on stdin, never in argv: here a StringIO stands
  # for stdin, with the piped or the terminal stub deciding which world it
  # is. The stub keychain is one table for the VM, so each home names a
  # profile of its own. Not async: it reads the verb's refusals and the
  # masked prompt from stderr, where another async test's output would land
  # too.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.ComputerCommand
  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Join
  alias FermixCore.Home.Role
  alias FermixTestSupport.PipedTerminal
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TtyTerminal

  @now ~U[2031-05-04 10:00:00Z]

  # A machine with no keyring client: the store says so, and takes nothing.
  defmodule NoKeyring do
    @moduledoc false
    @behaviour FermixCore.Setup.SecretWriter

    @impl true
    def available?(_opts \\ []), do: false

    @impl true
    def probe(opts \\ []) do
      %{
        store: Keyword.fetch!(opts, :store),
        state: :unavailable,
        sentence: "this machine has no keyring client"
      }
    end

    @impl true
    def put(_key, _value, _opts \\ []), do: flunk("a store that is not there is written to")

    @impl true
    def get(_key, _opts \\ []), do: flunk("a store that is not there is read")

    @impl true
    def delete(_key, _opts \\ []), do: flunk("a store that is not there is deleted from")

    @impl true
    def command_source(_key, _opts \\ []), do: %{source: :command, command: "", args: []}
  end

  setup do
    home = SafeRm.make_tmp_dir!("computer_command")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    profile = "cc-#{System.unique_integer([:positive])}"
    File.write!(Path.join(home, "config.toml"), ~s([fermix_core]\nprofile = "#{profile}"\n))
    %{home: home}
  end

  test "joins a stopped Fermix with the code piped in: the key, the join and the device role",
       ctx do
    {stdin, deps} = piped(code())

    output =
      capture_io(fn ->
        assert ComputerCommand.run(["join"], [home: ctx.home] ++ deps ++ stopped()) == 0
      end)

    assert output =~ "This computer joins your Fermix on studio-mac when Fermix starts here."
    # The digits are this computer's to show and the owner's to type (M97 §7.5).
    assert output =~ "It then shows six digits: type them on studio-mac to add it."
    # The one line it read was the code, and all of stdin it took.
    assert {"", _prompt} = StringIO.contents(stdin)
    assert Join.present?(ctx.home)
    assert {:ok, _keypair} = ComputerKey.read(ctx.home, store: :keyring)
    assert {:ok, %{role: :device}} = Role.configured(ctx.home)
  end

  # On a terminal the code is asked for with echo off, and the prompt, on
  # stderr, shows how much arrived and never what.
  test "on a terminal it asks for the code without echo and never shows it", ctx do
    the_code = code()
    {:ok, stdin} = StringIO.open(the_code <> "\n")
    deps = [home: ctx.home, terminal: TtyTerminal, device: stdin] ++ stopped()

    prompt =
      capture_io(:stderr, fn ->
        capture_io(fn -> assert ComputerCommand.run(["join"], deps) == 0 end)
      end)

    assert prompt ==
             "Code from Add a computer: (#{String.length(the_code)} characters)\n"

    refute prompt =~ the_code
    assert_received {:secret_input_echo, false}
    assert_received {:secret_input_echo, true}
    assert Join.present?(ctx.home)
  end

  # A code in argv is readable by every process here while the verb runs.
  test "a code on the command line is a usage error naming the stdin form", ctx do
    {_stdin, deps} = piped(code())

    error =
      capture_io(:stderr, fn ->
        assert ComputerCommand.run(["join", code()], [home: ctx.home] ++ deps ++ stopped()) ==
                 2
      end)

    assert error =~
             "fermix computer join: the code is not taken on the command line, where other " <>
               "programs here can read it. Run fermix computer join and paste the code when " <>
               "it asks, or pipe it in."

    assert error =~ "fermix computer join"
    refute error =~ "CODE"
    refute Join.present?(ctx.home)
    assert {:error, {:missing, :keyring}} = ComputerKey.read(ctx.home, store: :keyring)
  end

  test "nothing on stdin is refused before any key is made", ctx do
    {_stdin, deps} = piped(nil)

    error =
      capture_io(:stderr, fn ->
        assert ComputerCommand.run(["join"], [home: ctx.home] ++ deps ++ stopped()) == 1
      end)

    assert error ==
             "fermix computer join: No code was read. Paste the code from Add a computer " <>
               "when this asks for it, or pipe it in.\n"

    refute Join.present?(ctx.home)
    assert {:error, {:missing, :keyring}} = ComputerKey.read(ctx.home, store: :keyring)
    assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
  end

  # A probe whose connect timed out cannot tell whether Fermix runs here (a
  # starved machine's daemon may be there), so the join refuses and says so.
  test "refuses when it cannot tell whether Fermix runs here, and asks no code", ctx do
    {stdin, deps} = piped(code())
    unknown = [home: ctx.home, hello: fn -> {:error, :timeout} end, now: @now] ++ deps

    error =
      capture_io(:stderr, fn -> assert ComputerCommand.run(["join"], unknown) == 1 end)

    assert error =~ "fermix computer join: Fermix could not tell whether it is running here"
    assert error =~ "Make sure it is stopped, then run this again."
    assert {"fxenroll1." <> _rest, ""} = StringIO.contents(stdin)
    refute Join.present?(ctx.home)
  end

  test "refuses while Fermix runs here, and a code that is not a computer's, by name", ctx do
    {stdin, deps} = piped(code())
    running = [home: ctx.home, hello: fn -> {:ok, %{}} end, now: @now] ++ deps

    error =
      capture_io(:stderr, fn -> assert ComputerCommand.run(["join"], running) == 1 end)

    assert error =~ "fermix computer join: Fermix is running here."
    # Fermix runs here, so the code was never asked for.
    assert {"fxenroll1." <> _rest, ""} = StringIO.contents(stdin)

    {_stdin, deps} = piped(code(purpose: :candidate))

    error =
      capture_io(:stderr, fn ->
        assert ComputerCommand.run(["join"], [home: ctx.home] ++ deps ++ stopped()) == 1
      end)

    assert error =~ "sets up a server of your own"
    refute Join.present?(ctx.home)
    assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
  end

  # A release build serves no Always On until its home turns it on
  # (`Home.AlwaysOnRelease`), and a join is part of it.
  test "in a build without Always On it refuses in one sentence and reads nothing", ctx do
    {stdin, stdin_deps} = piped(code())
    deps = [home: ctx.home, always_on: false] ++ stdin_deps ++ stopped()

    error =
      capture_io(:stderr, fn -> assert ComputerCommand.run(["join"], deps) == 1 end)

    assert error == "fermix computer join: Always On is not in this release of Fermix yet.\n"
    assert {"fxenroll1." <> _rest, ""} = StringIO.contents(stdin)
    refute Join.present?(ctx.home)
    assert {:error, {:missing, :keyring}} = ComputerKey.read(ctx.home, store: :keyring)
  end

  # No engine tree runs, so no command host owns a keychain helper: a store
  # that cannot be used is refused in its own sentence, and nothing is left.
  test "a secret store it cannot reach is refused by name, leaving nothing behind", ctx do
    {_stdin, stdin_deps} = piped(code())
    deps = [home: ctx.home, key_opts: [impl: NoKeyring]] ++ stdin_deps ++ stopped()

    error =
      capture_io(:stderr, fn -> assert ComputerCommand.run(["join"], deps) == 1 end)

    assert error ==
             "fermix computer join: Fermix cannot use this computer's key: this machine " <>
               "has no keyring client.\n"

    refute error =~ "command host"
    refute Join.present?(ctx.home)
    assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
  end

  test "anything else is a usage error" do
    capture_io(:stderr, fn ->
      assert ComputerCommand.run([], stopped()) == 2
      assert ComputerCommand.run(["leave", "x"], stopped()) == 2
    end)
  end

  defp stopped, do: [hello: fn -> {:error, :not_running} end, now: @now]

  # Stdin as a pipe or a file: one line holding `code`, or nothing at all.
  defp piped(code) do
    {:ok, stdin} = StringIO.open(if code, do: code <> "\n", else: "")
    {stdin, [terminal: PipedTerminal, device: stdin]}
  end

  defp code(overrides \\ []) do
    facts =
      Map.merge(
        %{
          purpose: :computer,
          secret: :binary.copy(<<0x5A>>, 32),
          gateway_pk: :binary.copy(<<0x3C>>, 32),
          node_id: String.duplicate("4f", 32),
          relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
          relays_rev: "0123456789abcdef",
          name: "studio-mac",
          expires_at: ~U[2031-05-04 10:30:00Z]
        },
        Map.new(overrides)
      )

    {:ok, code} = EnrollmentCode.encode(facts)
    code
  end
end
