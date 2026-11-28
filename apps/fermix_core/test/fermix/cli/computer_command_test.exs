defmodule Fermix.CLI.ComputerCommandTest do
  # M97 §3.1, M102 J2 (D4): `fermix computer join` hands the code to the
  # running Fermix's `computer.join.start`, the one join path the apps take.
  # The code comes on stdin, never in argv: here a StringIO stands for stdin,
  # with the piped or the terminal stub deciding which world it is. Not
  # async: it reads the verb's refusals and the masked prompt from stderr,
  # where another async test's output would land too, and its running Fermix
  # is a socket under a FERMIX_HOME of its own.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.ComputerCommand
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Join
  alias FermixCore.Home.Role
  alias FermixCore.Management.ComputerLink
  alias FermixTestSupport.FakeDaemonSocket
  alias FermixTestSupport.PipedTerminal
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TtyTerminal

  @now ~U[2031-05-04 10:00:00Z]
  @joining "This computer is joining your Fermix. Once Fermix restarts here, fermix home " <>
             "status shows six digits: type them in Always On on a computer already in your " <>
             "Fermix.\n"

  setup do
    home = SafeRm.make_tmp_dir!("computer_command")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    profile!(home)
    %{home: home}
  end

  # M102 J2: a computer its server removed while its Fermix was stopped hears
  # of it only once that Fermix runs and its relay dials, which marks the
  # link revoked. The terminal then joins as the apps do, through the running
  # Fermix, over its real control socket.
  test "joins through the running Fermix, which lets go of a link its server revoked" do
    home = FakeDaemonSocket.fermix_home!()
    profile!(home)
    test = self()
    :ok = Join.start(home, code(), join_opts(test))
    :ok = Join.finish(home, approved(), join_opts(test))
    revoked!(home)
    assert_received :restarted
    assert_received :restarted

    daemon =
      FakeDaemonSocket.serve_v1(home, 2, fn
        "hello", _params -> {:ok, %{"engine" => %{"distribution_identity" => "standalone"}}}
        "computer.join.start", %{"code" => code} -> engine_join(home, code, join_opts(test))
      end)

    {_stdin, deps} = piped(code())

    output =
      capture_io(fn -> assert ComputerCommand.run(["join"], [home: home] ++ deps) == 0 end)

    Task.await(daemon, 10_000)
    assert output == @joining
    assert_received {:fake_daemon_v1, "hello", %{}}
    assert_received {:fake_daemon_v1, "computer.join.start", %{"code" => "fxenroll1." <> _rest}}
    assert_received :restarted
    refute File.exists?(DesktopLink.path(home))
    assert {:ok, %{"phase" => "dialing"}} = Join.read(home)
    assert {:ok, %{role: :device}} = Role.configured(home)
  end

  test "joins with the code piped in, and says where its digits show", ctx do
    {stdin, deps} = piped(code())
    client = engine(%{"joining" => true})

    output =
      capture_io(fn ->
        assert ComputerCommand.run(["join"], [home: ctx.home, client: client] ++ deps) == 0
      end)

    # The digits show on this computer, and the owner types them where the
    # home asks, never on the server, which has no screen (M102 N9, D7).
    assert output == @joining
    refute output =~ "studio-mac"
    # The one line it read was the code, and all of stdin it took.
    assert {"", _prompt} = StringIO.contents(stdin)
    assert_received {:sent, "computer.join.start", %{"code" => "fxenroll1." <> _rest}, opts}
    assert opts[:socket_path] == Path.join(ctx.home, "daemon.sock")
  end

  # On a terminal the code is asked for with echo off, and the prompt, on
  # stderr, shows how much arrived and never what.
  test "on a terminal it asks for the code without echo and never shows it", ctx do
    the_code = code()
    {:ok, stdin} = StringIO.open(the_code <> "\n")
    client = engine(%{"joining" => true})
    deps = [home: ctx.home, client: client, terminal: TtyTerminal, device: stdin]

    prompt =
      capture_io(:stderr, fn ->
        capture_io(fn -> assert ComputerCommand.run(["join"], deps) == 0 end)
      end)

    assert prompt == "Code from Add a computer: (#{String.length(the_code)} characters)\n"
    refute prompt =~ the_code
    assert_received {:secret_input_echo, false}
    assert_received {:secret_input_echo, true}
    assert_received {:sent, "computer.join.start", %{"code" => ^the_code}, _opts}
  end

  # The apps join through the running Fermix, and so does the terminal: with
  # Fermix stopped there is nothing to join through, so no code is read.
  test "with Fermix stopped it refuses before it reads a code", ctx do
    {stdin, deps} = piped(code())
    client = fn "hello", %{}, _opts -> {:error, :not_running} end

    error =
      capture_io(:stderr, fn ->
        assert ComputerCommand.run(["join"], [home: ctx.home, client: client] ++ deps) == 1
      end)

    assert error ==
             "fermix computer join: Fermix is not running here. Start it, then run this " <>
               "again.\n"

    assert {"fxenroll1." <> _rest, ""} = StringIO.contents(stdin)
    refute Join.present?(ctx.home)
  end

  # A connect that timed out cannot tell whether Fermix runs here (a starved
  # machine's daemon may be there), so the verb says so and reads no code.
  test "refuses when it cannot tell whether Fermix runs here, and reads no code", ctx do
    {stdin, deps} = piped(code())
    client = fn "hello", %{}, _opts -> {:error, :timeout} end

    error =
      capture_io(:stderr, fn ->
        assert ComputerCommand.run(["join"], [home: ctx.home, client: client] ++ deps) == 1
      end)

    assert error ==
             "fermix computer join: Fermix could not tell whether it is running: its control " <>
               "socket did not answer in time.\n"

    assert {"fxenroll1." <> _rest, ""} = StringIO.contents(stdin)
  end

  # The engine's refusal is its own sentence: a code that is not a
  # computer's, a home of its own, a link its relay has not taken to the
  # server yet (`Home.Join.error_sentence/1`).
  test "the running Fermix's refusal is said in its own words", ctx do
    said = Join.error_sentence(:server_not_reached)
    details = %{"capability" => "computer", "sentence" => said}
    client = engine({:error, {:management_error, "unavailable", "unavailable", details}})
    {_stdin, deps} = piped(code())

    error =
      capture_io(:stderr, fn ->
        assert ComputerCommand.run(["join"], [home: ctx.home, client: client] ++ deps) == 1
      end)

    assert error == "fermix computer join: " <> said <> "\n"
  end

  # A code in argv is readable by every process here while the verb runs.
  test "a code on the command line is a usage error naming the stdin form", ctx do
    {_stdin, deps} = piped(code())
    client = fn method, _params, _opts -> flunk("#{method} was sent") end

    error =
      capture_io(:stderr, fn ->
        assert ComputerCommand.run(["join", code()], [home: ctx.home, client: client] ++ deps) ==
                 2
      end)

    assert error =~
             "fermix computer join: the code is not taken on the command line, where other " <>
               "programs here can read it. Run fermix computer join and paste the code when " <>
               "it asks, or pipe it in."

    refute error =~ "CODE"
  end

  test "nothing on stdin is refused before the code is sent", ctx do
    {_stdin, deps} = piped(nil)
    client = engine(%{"joining" => true})

    error =
      capture_io(:stderr, fn ->
        assert ComputerCommand.run(["join"], [home: ctx.home, client: client] ++ deps) == 1
      end)

    assert error ==
             "fermix computer join: No code was read. Paste the code from Add a computer " <>
               "when this asks for it, or pipe it in.\n"

    refute_received {:sent, "computer.join.start", _params, _opts}
  end

  test "anything else is a usage error" do
    capture_io(:stderr, fn ->
      assert ComputerCommand.run([]) == 2
      assert ComputerCommand.run(["leave", "x"]) == 2
    end)
  end

  # A running Fermix: it answers `hello`, and `computer.join.start` with
  # `answer` (a result, or an error as the client gives it back).
  defp engine(answer) do
    test = self()

    fn
      "hello", %{}, _opts ->
        {:ok, %{"engine" => %{"distribution_identity" => "standalone"}}}

      "computer.join.start", params, opts ->
        send(test, {:sent, "computer.join.start", params, opts})
        if is_map(answer), do: {:ok, answer}, else: answer
    end
  end

  # The engine's own answer to `computer.join.start`, as its router puts it
  # on the wire.
  defp engine_join(home, code, opts) do
    case ComputerLink.join_start(code, [home: home] ++ opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:unavailable, capability, sentence}} ->
        {:error, "unavailable", "unavailable",
         %{"capability" => capability, "sentence" => sentence}}

      {:error, {:invalid_params, field, sentence}} ->
        {:error, "invalid_params", "invalid params", %{"field" => field, "sentence" => sentence}}
    end
  end

  defp join_opts(test) do
    [
      now: @now,
      restart: fn -> send(test, :restarted) && :ok end,
      release: fn _which -> :ok end,
      link_status: fn -> %{primary: nil, desktops: [], enrollment: nil} end
    ]
  end

  defp profile!(home) do
    profile = "cc-#{System.unique_integer([:positive])}"
    File.write!(Path.join(home, "config.toml"), ~s([fermix_core]\nprofile = "#{profile}"\n))
  end

  # The link as the relay leaves it once the server ended a session as no
  # longer knowing this computer (`DesktopLink`'s `revoked`).
  defp revoked!(home) do
    link = DesktopLink.path(home)
    revoked = link |> File.read!() |> Jason.decode!() |> Map.put("revoked", true)
    File.write!(link, Jason.encode!(revoked))
  end

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

  # The server's word once the owner added this computer.
  defp approved do
    %{
      "device_id" => "7e1f0c2a-3b4d-4e5f-8a6b-7c8d9e0f1a2b",
      "name" => "loft-linux",
      "primary_epoch" => 6,
      "primary" => %{
        "name" => "studio-mac",
        "node_id" => String.duplicate("4f", 32),
        "relays" => [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        "relays_rev" => "0123456789abcdef"
      }
    }
  end
end
