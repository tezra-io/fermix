defmodule FermixChannels.Desktop.TwoEnginesInvokeTest do
  # M97 §5.2, §6: a server asks its computer, over the real link, with each
  # engine's own home and processes in one VM (`TwoEngines`). The answer
  # survives a dropped session; an effect whose answer is lost is never sent
  # again and is not known; a read whose answer is lost is asked again under
  # a new id. async: false: the relay's dial names are VM-wide.
  use ExUnit.Case, async: false

  alias FermixChannels.Test.TwoEngines
  alias FermixChannels.Test.TwoEngines.Hold
  alias FermixChannels.Test.TwoEngines.Touch
  alias FermixChannels.Test.TwoEngines.Wait
  alias FermixCore.Computers.Capabilities.System, as: SystemCapability
  alias FermixCore.Computers.Journal
  alias FermixCore.Computers.Outcome

  setup do
    %{engines: TwoEngines.start!()}
  end

  test "an echo goes to the computer and back, and the computer journals it", %{engines: e} do
    task = TwoEngines.call(e, SystemCapability, "echo", %{"text" => "hello from the server"})

    assert {:ok, %Outcome{status: :ok, result: result} = outcome} = Task.await(task, 15_000)
    assert result["text"] == "hello from the server"
    assert is_binary(result["engine_version"])
    assert outcome.computer == e.device_id

    assert {:ok, %{entries: [entry], more: false}} = Journal.list(Journal.dir(e.root))
    assert %{id: id, capability: "system", op: "echo", status: "ok", origin: "chat"} = entry
    assert id == outcome.invocation
  end

  test "an answer that went while the session was down arrives once it is back",
       %{engines: e} do
    task = TwoEngines.call(e, Wait, "wait", %{"name" => "long"})
    {run, nil} = TwoEngines.running("long")

    ExUnit.CaptureLog.capture_log(fn ->
      :ok = TwoEngines.drop_session!(e)
      TwoEngines.finish(run, {:ok, %{"waited" => true}, nil})
      await_journaled(e.root, "ok")
      :ok = TwoEngines.reconnect!(e)
    end)

    assert {:ok, %Outcome{result: %{"waited" => true}}} = Task.await(task, 15_000)
    assert {:ok, %{entries: [_one]}} = Journal.list(Journal.dir(e.root))
  end

  test "an effect whose answer is lost is not known, and is never sent again", %{engines: e} do
    task = TwoEngines.call(e, Touch, "touch", %{"name" => "plan.txt"})
    {_run, nil} = TwoEngines.running("plan.txt")

    ExUnit.CaptureLog.capture_log(fn ->
      :ok = TwoEngines.drop_session!(e)
      crash_admission!(e)
      :ok = TwoEngines.reconnect!(e)
    end)

    assert {:error, %Outcome{status: :unknown} = outcome} = Task.await(task, 15_000)

    assert Outcome.sentence(outcome, "studio Mac") ==
             "Fermix lost studio Mac's answer, so whether touch plan.txt happened is not " <>
               "known. Check before doing it again."

    assert File.read!(Path.join(e.root, "plan.txt")) == "touched"
    assert {:ok, %{entries: [entry]}} = Journal.list(Journal.dir(e.root))
    assert %{status: "unknown", capability: "touch"} = entry
    refute_received {:running, "plan.txt", _pid, _part}
  end

  test "a read whose answer is lost is asked again under a new id", %{engines: e} do
    task = TwoEngines.call(e, Wait, "wait", %{"name" => "look"})
    {_run, nil} = TwoEngines.running("look")

    ExUnit.CaptureLog.capture_log(fn ->
      :ok = TwoEngines.drop_session!(e)
      crash_admission!(e)
      :ok = TwoEngines.reconnect!(e)
    end)

    {again, nil} = TwoEngines.running("look")
    TwoEngines.finish(again, {:ok, %{"seen" => 2}, nil})

    assert {:ok, %Outcome{result: %{"seen" => 2}, invocation: second}} = Task.await(task, 15_000)
    assert {:ok, %{entries: [newest, first]}} = Journal.list(Journal.dir(e.root))
    assert newest.id == second and newest.status == "ok"
    assert first.status == "unknown"
    refute first.id == second
  end

  # The computer's invocations restart while its session stays up: no
  # session ends, so no caller would ask. The computer tells the server of
  # each run the restart ended, and a long-lived read, which has no
  # deadline (a Messages or screen watch), is asked again at once.
  test "a restart under a live session is told to the server, which asks a watch again",
       %{engines: e} do
    task = TwoEngines.call(e, Hold, "hold", %{"name" => "watch"}, deadline_ms: 0)
    {_run, nil} = TwoEngines.running("watch")

    ExUnit.CaptureLog.capture_log(fn -> crash_admission!(e) end)

    {again, nil} = TwoEngines.running("watch")
    TwoEngines.finish(again, {:ok, %{"seen" => 2}, nil})

    assert {:ok, %Outcome{result: %{"seen" => 2}, invocation: second}} = Task.await(task, 15_000)
    assert {:ok, %{entries: [newest, first]}} = Journal.list(Journal.dir(e.root))
    assert newest.id == second and newest.status == "ok"
    assert first.status == "unknown"
  end

  test "an effect a restart under a live session ended is said not known, at once",
       %{engines: e} do
    task = TwoEngines.call(e, Touch, "touch", %{"name" => "notes.txt"}, deadline_ms: 600_000)
    {_run, nil} = TwoEngines.running("notes.txt")

    ExUnit.CaptureLog.capture_log(fn -> crash_admission!(e) end)

    assert {:error, %Outcome{status: :unknown}} = Task.await(task, 15_000)
    refute_received {:running, "notes.txt", _pid, _part}
  end

  # A caller that ends is the server's one way to stop what it asked: its
  # waiter cancels the request on the computer, which only ever follows the
  # request, since the caller sent that before it ended.
  test "a caller that ends has its run stopped on the computer", %{engines: e} do
    task = TwoEngines.call(e, Wait, "wait", %{"name" => "stop me"})
    {run, nil} = TwoEngines.running("stop me")
    ref = Process.monitor(run)

    _ended = Task.shutdown(task, :brutal_kill)

    assert_receive {:DOWN, ^ref, :process, ^run, _reason}, 10_000
    await_journaled(e.root, "cancelled")
  end

  # A file above 256 KiB rides the bulk lane while its request and answer
  # ride the interactive one; each still arrives whole.
  test "a large file goes up with its request and comes back with its answer", %{engines: e} do
    upload = :crypto.strong_rand_bytes(300 * 1_024)
    download = :crypto.strong_rand_bytes(280 * 1_024)

    task =
      TwoEngines.call(e, Wait, "wait", %{"name" => "files"}, part: {upload, "image/png"})

    {run, part} = TwoEngines.running("files")
    assert part == upload
    TwoEngines.finish(run, {:ok, %{"kind" => "picture"}, download})

    assert {:ok, %Outcome{result: %{"kind" => "picture"}, part_bytes: ^download}} =
             Task.await(task, 15_000)
  end

  test "the master switch off at the computer refuses the server", %{engines: e} do
    Agent.update(e.switch_agent, &Keyword.put(&1, :enabled, false))
    task = TwoEngines.call(e, SystemCapability, "echo", %{"text" => "hello"})

    assert {:error, %Outcome{status: :refused, refusal: :off} = outcome} =
             Task.await(task, 15_000)

    assert Outcome.sentence(outcome, "studio Mac") =~
             "studio Mac has everything Fermix on your server may use switched off"
  end

  # Its Admission dies under a run, as a crash would: the run goes with it,
  # and the restarted Admission journals it unknown (interrupted).
  # The restart closes the run it ended as unknown; a read the server asks
  # again at once may be journaled after it.
  defp crash_admission!(e) do
    admission = Process.whereis(e.admission)
    ref = Process.monitor(admission)
    Process.exit(admission, :kill)
    assert_receive {:DOWN, ^ref, :process, ^admission, :killed}
    await_closed_unknown(e.root)
  end

  defp await_closed_unknown(root, attempts \\ 1_000) do
    case Journal.list(Journal.dir(root)) do
      {:ok, %{entries: entries}} when is_list(entries) and entries != [] ->
        if Enum.any?(entries, &(&1.status == "unknown")),
          do: :ok,
          else: retry_closed_unknown(root, attempts)

      _not_yet ->
        retry_closed_unknown(root, attempts)
    end
  end

  defp retry_closed_unknown(_root, 0), do: flunk("the computer never journaled unknown")

  defp retry_closed_unknown(root, attempts) do
    # sleep: polls the computer's journal, which announces nothing
    Process.sleep(10)
    await_closed_unknown(root, attempts - 1)
  end

  defp await_journaled(root, status, attempts \\ 1_000) do
    case Journal.list(Journal.dir(root)) do
      {:ok, %{entries: [%{status: ^status} | _older]}} ->
        :ok

      _not_yet when attempts == 0 ->
        flunk("the computer never journaled #{status}")

      _not_yet ->
        # sleep: polls the computer's journal, which announces nothing
        Process.sleep(10)
        await_journaled(root, status, attempts - 1)
    end
  end
end
