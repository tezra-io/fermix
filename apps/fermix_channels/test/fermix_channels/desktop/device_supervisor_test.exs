defmodule FermixChannels.Desktop.DeviceSupervisorTest do
  # Always On's move back (design §2, §14 "Nested start"): a desktop receives
  # the home back in its own device engine, so the candidate subtree runs
  # under the device tree beside the relay, and nothing it does takes the
  # relay down. async: false: the device tree registers the names a device
  # engine runs (the dial helper, the relay, the candidate's endpoint).
  use ExUnit.Case, async: false

  alias FermixChannels.Desktop.DeviceSupervisor
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Home.Candidate, as: CandidateProcess
  alias FermixChannels.Home.CandidateSupervisor
  alias FermixChannels.Home.Link
  alias FermixChannels.Test.DesktopRail
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Moved

  @now ~U[2031-05-04 10:00:00Z]

  setup do
    %{root: DesktopRail.root!("fx-ds")}
  end

  test "a home holding a candidate starts its subtree beside the dial subtree, and only then",
       %{root: root} do
    assert DeviceSupervisor.children(root) == []

    linked!(root)
    assert [%{id: :dial, type: :supervisor}] = DeviceSupervisor.children(root)

    return_candidate!(root)

    assert [%{id: :dial}, %{id: CandidateSupervisor, restart: :temporary, type: :supervisor}] =
             DeviceSupervisor.children(root)
  end

  test "a boot of a desktop that holds a move back runs the relay and the candidate side by side",
       %{root: root} do
    linked!(root)
    return_candidate!(root)
    start_supervised!({DeviceSupervisor, root: root})

    assert is_pid(Process.whereis(Relay))
    assert is_pid(Process.whereis(CandidateSupervisor))
    assert {:ok, %{"phase" => "enrolled"}} = Candidate.read_state(root)
  end

  test "the move back's receiver starts on a running device tree and its end never takes the relay down",
       %{root: root} do
    linked!(root)
    tree = start_supervised!({DeviceSupervisor, root: root})
    relay = Process.whereis(Relay)
    assert Process.whereis(CandidateSupervisor) == nil

    return_candidate!(root)
    assert :ok = Link.start_return(root)
    assert :ok = Link.start_return(root)
    candidate = Process.whereis(CandidateSupervisor)
    assert is_pid(candidate)
    assert is_pid(Process.whereis(CandidateProcess))

    # One that gives up is not started again until asked: the relay and the
    # tree it runs under carry on as they were.
    ref = Process.monitor(candidate)
    crash_past_its_limit!()
    assert_receive {:DOWN, ^ref, :process, ^candidate, :shutdown}, 10_000
    assert Process.alive?(tree)
    assert Process.whereis(Relay) == relay
    assert Process.whereis(CandidateSupervisor) == nil

    # Cancel stops it; stopping what does not run is nothing to do.
    assert :ok = Link.start_return(root)
    assert :ok = Link.stop_return()
    assert Process.whereis(CandidateSupervisor) == nil
    assert :ok = Link.stop_return()
    assert Process.whereis(Relay) == relay
  end

  test "a subtree that cannot start is logged and leaves the device tree running",
       %{root: root} do
    linked!(root)
    return_candidate!(root)
    # A name the candidate's subtree registers is taken, so it refuses to start.
    squatter = spawn_link(fn -> Process.sleep(:infinity) end)
    Process.register(squatter, FermixChannels.Home.CandidateConnections)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!({DeviceSupervisor, root: root})
      end)

    assert log =~ "the move back to this computer could not start receiving"
    assert is_pid(Process.whereis(Relay))
    assert Process.whereis(CandidateSupervisor) == nil

    ref = Process.monitor(squatter)
    Process.unlink(squatter)
    Process.exit(squatter, :kill)
    assert_receive {:DOWN, ^ref, :process, ^squatter, :killed}
  end

  test "no device tree is running: there is nothing to start a move back under", %{root: root} do
    assert {:error, :no_device_tree} = Link.start_return(root)
    assert :ok = Link.stop_return()
  end

  # Its candidate process killed more often than its supervisor restarts it
  # (three times in five seconds), so the subtree gives up.
  defp crash_past_its_limit! do
    Enum.reduce(1..4, nil, fn _crash, killed ->
      pid = HomeMove.await(fn -> restarted(killed) end)
      Process.exit(pid, :kill)
      pid
    end)
  end

  defp restarted(killed) do
    case Process.whereis(CandidateProcess) do
      ^killed -> nil
      pid -> pid
    end
  end

  # A link the relay refuses by name still makes the home a linked desktop,
  # so the dial subtree starts and the relay runs without dialing.
  defp linked!(root) do
    File.mkdir_p!(Path.dirname(DesktopLink.path(root)))
    File.write!(DesktopLink.path(root), "{}")
    :ok = Moved.write(root, %{epoch: 4, moved_at: @now, to: "north-box"})
  end

  # A return candidate written as `home.act move_back` writes it, then
  # recorded as enrolled, so it waits for the move and dials nobody.
  defp return_candidate!(root) do
    {:ok, code} = EnrollmentCode.encode(code_facts())

    {:ok, _state} =
      Candidate.prepare_return(root, {:return, code},
        now: @now,
        role: :device,
        restarts_itself?: true
      )

    {:ok, state} = Candidate.read_state(root)
    :ok = Candidate.drop_code(root)

    enrolled =
      Map.merge(state, %{
        "phase" => "enrolled",
        "candidate_id" => "cand-4f2a",
        "enrolled_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "listen_until" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3_600))
      })

    :ok = Candidate.put_state(root, enrolled, @now)
  end

  defp code_facts do
    %{
      secret: :binary.copy(<<0x5A>>, 32),
      gateway_pk: :binary.copy(<<0x3C>>, 32),
      node_id: String.duplicate("4f", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      relays_rev: "0123456789abcdef",
      name: "north-box",
      expires_at: ~U[2031-05-04 10:30:00Z]
    }
  end
end
