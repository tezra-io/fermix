defmodule Fermix.CLI.ComputerCommandTest do
  # M97 §3.1: `fermix computer join CODE`, with no engine tree, against a
  # stopped Fermix. The stub keychain is one table for the VM, so each home
  # names a profile of its own. Not async: it reads the verb's refusals from
  # stderr, where another async test's output would land too.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.ComputerCommand
  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Join
  alias FermixCore.Home.Role
  alias FermixTestSupport.SafeRm

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

  test "joins a stopped Fermix: the key, the join and the device role, for the next start",
       ctx do
    output =
      capture_io(fn ->
        assert ComputerCommand.run(["join", code()], [home: ctx.home] ++ stopped()) == 0
      end)

    assert output =~ "This computer joins your Fermix on studio-mac when Fermix starts here."
    assert Join.present?(ctx.home)
    assert {:ok, _keypair} = ComputerKey.read(ctx.home, store: :keyring)
    assert {:ok, %{role: :device}} = Role.configured(ctx.home)
  end

  test "refuses while Fermix runs here, and a code that is not a computer's, by name", ctx do
    running = [home: ctx.home, hello: fn -> {:ok, %{}} end, now: @now]

    error =
      capture_io(:stderr, fn -> assert ComputerCommand.run(["join", code()], running) == 1 end)

    assert error =~ "fermix computer join: Fermix is running here."

    error =
      capture_io(:stderr, fn ->
        assert ComputerCommand.run(
                 ["join", code(purpose: :candidate)],
                 [home: ctx.home] ++ stopped()
               ) ==
                 1
      end)

    assert error =~ "sets up a server of your own"
    refute Join.present?(ctx.home)
    assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
  end

  # A release build serves no Always On until its home turns it on
  # (`Home.AlwaysOnRelease`), and a join is part of it.
  test "in a build without Always On it refuses in one sentence and writes nothing", ctx do
    deps = [home: ctx.home, always_on: false] ++ stopped()

    error =
      capture_io(:stderr, fn -> assert ComputerCommand.run(["join", code()], deps) == 1 end)

    assert error == "fermix computer join: Always On is not in this release of Fermix yet.\n"
    refute Join.present?(ctx.home)
    assert {:error, {:missing, :keyring}} = ComputerKey.read(ctx.home, store: :keyring)
  end

  # No engine tree runs, so no command host owns a keychain helper: a store
  # that cannot be used is refused in its own sentence, and nothing is left.
  test "a secret store it cannot reach is refused by name, leaving nothing behind", ctx do
    deps = [home: ctx.home, key_opts: [impl: NoKeyring]] ++ stopped()

    error =
      capture_io(:stderr, fn -> assert ComputerCommand.run(["join", code()], deps) == 1 end)

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
      assert ComputerCommand.run(["join"], stopped()) == 2
      assert ComputerCommand.run(["leave", "x"], stopped()) == 2
    end)
  end

  defp stopped, do: [hello: fn -> {:error, :not_running} end, now: @now]

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
