defmodule FermixCore.ComputerUse.ActionWorkerTest do
  @moduledoc """
  The process that owns a computer-use session's driver, and therefore its Port
  (M42 slice 2 §6). These pin the parts a `Session` test cannot see: that the
  driver is started HERE (so a failure to start is the session's failure to
  start), that the one-time input-control probe is answered from here, that the
  Port's own messages land here, and that the driver is released on every exit —
  including the one where the session dies without warning.
  """

  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.ActionWorker

  defmodule StubDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      case Keyword.get(opts, :start_error) do
        nil ->
          {:ok,
           %{
             test_pid: Keyword.fetch!(opts, :test_pid),
             probe: Keyword.get(opts, :probe, {:ok, %{"input_control" => true}})
           }}

        error ->
          {:error, error}
      end
    end

    @impl true
    def execute(%{test_pid: pid, probe: probe}, %{"action" => "probe"}) do
      send(pid, :driver_probe)
      probe
    end

    def execute(%{test_pid: pid}, request) do
      send(pid, {:driver_execute, request})
      {:ok, %{"ok" => true}}
    end

    @impl true
    def stop(%{test_pid: pid}) do
      send(pid, :driver_stop)
      :ok
    end
  end

  defp start_worker(driver_opts) do
    ActionWorker.start_link(
      driver: {StubDriver, [test_pid: self()] ++ driver_opts},
      session: self()
    )
  end

  test "a driver that cannot start fails the worker's start with the driver's reason" do
    Process.flag(:trap_exit, true)

    assert {:error, {:sidecar_missing, "/nope"}} =
             start_worker(start_error: {:sidecar_missing, "/nope"})
  end

  # Read once at start, never prompted for: the probe is a driver call, so it runs
  # where the driver is, and the session reads the answer rather than the wire.
  test "the input-control probe runs at start and its answer is readable" do
    {:ok, worker} = start_worker(probe: {:ok, %{"input_control" => false}})

    assert_received :driver_probe
    refute ActionWorker.input_control?(worker)
  end

  # Absent or failed probe reads as granted — only the explicit denied state is
  # refused, so a broken probe cannot brick looking.
  test "a probe that fails is treated as granted" do
    {:ok, worker} = start_worker(probe: {:error, :boom})

    assert ActionWorker.input_control?(worker)
  end

  # The sidecar's exit status is reported as its own stop reason, unclassified:
  # the session decides what a status MEANS (75 is compux's designed capture-stall
  # self-reap), because that is where the wedge counter and the lifecycle bookend
  # read the same shapes.
  test "the sidecar exiting stops the worker with the raw status" do
    Process.flag(:trap_exit, true)
    {:ok, worker} = start_worker([])

    send(worker, {:compux_sidecar_exit, self(), 75})

    assert_receive {:EXIT, ^worker, {:shutdown, {:sidecar_exit_status, 75}}}
    assert_receive :driver_stop
  end

  # A transport that killed the sidecar over an unusable wire says so with a term,
  # not a number: an exit code there could only ever be the signal it sent.
  test "a poisoned wire is carried through as its own reason, not a status" do
    Process.flag(:trap_exit, true)
    {:ok, worker} = start_worker([])

    send(worker, {:compux_sidecar_exit, self(), {:poisoned, {:malformed_frame, :nope}}})

    assert_receive {:EXIT, ^worker,
                    {:shutdown, {:sidecar_exit_status, {:poisoned, {:malformed_frame, :nope}}}}}
  end

  # Decoded and forwarded by the transport; nothing emits one at this protocol
  # version, so the worker must name it rather than die on an unexpected message.
  test "a session event is ignored without crashing the worker" do
    {:ok, worker} = start_worker([])

    send(
      worker,
      {:compux_session_event, self(), %Compux.Frame.SessionEvent{kind: "x", payload: %{}}}
    )

    assert ActionWorker.input_control?(worker)
  end

  # The load-bearing teardown: `stop/1` closes the Port AND kills the OS process,
  # and a session that is killed outright still has to produce it, or a wedged
  # sidecar is left holding screen capture for every later client on the machine.
  test "the driver is released when the process that started the worker dies" do
    test_pid = self()

    session =
      spawn(fn ->
        {:ok, _worker} =
          ActionWorker.start_link(driver: {StubDriver, [test_pid: test_pid]}, session: self())

        receive do: (:never -> :ok)
      end)

    assert_receive :driver_probe
    Process.exit(session, :kill)

    assert_receive :driver_stop
  end
end
