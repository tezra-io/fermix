defmodule FermixCore.Trace.WriteFailureTest do
  @moduledoc """
  A full disk never stops the engine (M75 L14). `Trace` is an early child of
  core's `:rest_for_one` supervisor, so a write it cannot make must be dropped,
  not raised: a crash there restarts every child after it, and a disk that
  stays full repeats the crash until the supervisor gives up and core exits.

  The disk is an injected device in front of the real file: while the test
  says the disk is full it answers every write as the file server answers for
  a full disk (`{:error, :enospc}`), so the refusal reaches Trace as a real
  one does, without filling a real disk. A failure is logged once when it
  starts and once when a later entry is written again, with the count of the
  entries dropped in between, so these tests count log lines and run alone.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Trace
  alias FermixTestSupport.SafeRm

  @today ~D[2026-10-30]

  defmodule Device do
    @moduledoc false
    # The day's real file behind an IO device that asks `disk` at each request:
    # `:full` refuses a write and `:bad_close` a close with `:enospc`, as the
    # file server does for a full disk; otherwise the file does the work.
    def open(path, disk) do
      {:ok, file} = File.open(path, [:append, :binary])
      {:ok, spawn_link(fn -> loop(file, disk) end)}
    end

    defp loop(file, disk) do
      receive do
        {:io_request, from, ref, {:put_chars, _encoding, chars}} ->
          send(from, {:io_reply, ref, write(file, chars, state(disk))})
          loop(file, disk)

        {:file_request, from, ref, :close} ->
          :ok = File.close(file)
          send(from, {:file_reply, ref, close(state(disk))})
      end
    end

    defp state(disk), do: Agent.get(disk, & &1.state)
    defp write(_file, _chars, :full), do: {:error, :enospc}
    defp write(file, chars, _state), do: :file.write(file, chars)
    defp close(:bad_close), do: {:error, :enospc}
    defp close(_state), do: :ok
  end

  setup do
    base = SafeRm.make_tmp_dir!("trace-write-failure")
    on_exit(fn -> SafeRm.rm_rf!(base) end)
    disk = start_supervised!({Agent, fn -> %{state: :room, today: @today} end})
    %{base: base, disk: disk}
  end

  # The disk the trace writes to: `:no_open` refuses the open itself, as a
  # full disk refuses a new day's file; any other state opens the device.
  defp open_on(disk) do
    fn path ->
      case Agent.get(disk, & &1.state) do
        :no_open -> {:error, :enospc}
        _state -> Device.open(path, disk)
      end
    end
  end

  defp set(disk, key, value), do: Agent.update(disk, &Map.put(&1, key, value))

  defp start_trace(base, disk) do
    name = :"trace_write_failure_#{System.unique_integer([:positive])}"

    opts = [
      base_dir: base,
      name: name,
      open: open_on(disk),
      today: fn -> Agent.get(disk, & &1.today) end,
      timer_enabled: false
    ]

    {name, opts}
  end

  defp record(name, n), do: Trace.record(:llm_call, "main", %{n: n}, server: name)

  defp entries(base, date) do
    path = Path.join([base, Date.to_iso8601(date), "llm_call.jsonl"])

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> Jason.decode!() |> Map.fetch!("n")))
  end

  defp lines(log, text), do: log |> String.split("\n") |> Enum.count(&(&1 =~ text))

  test "a write the disk refuses is dropped and logged once; Trace and the children after it keep running",
       %{base: base, disk: disk} do
    {name, opts} = start_trace(base, disk)
    after_trace = :"after_trace_#{System.unique_integer([:positive])}"

    supervisor =
      start_supervised!(%{
        id: :tree,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             [
               {Trace, opts},
               %{id: :after, start: {Agent, :start_link, [fn -> :ok end, [name: after_trace]]}}
             ],
             [strategy: :rest_for_one]
           ]}
      })

    trace = Process.whereis(name)
    later = Process.whereis(after_trace)
    set(disk, :state, :full)

    log =
      capture_log(fn ->
        for n <- 1..6, do: record(name, n)
        :sys.get_state(name)
      end)

    assert Process.whereis(name) == trace, "Trace restarted: a full disk crashed it"
    assert Process.whereis(after_trace) == later, "a Trace crash restarted the children after it"
    assert Process.alive?(supervisor)
    assert lines(log, "Trace cannot write #{base}") == 1, log
    assert log =~ "no space left on device"
  end

  test "an open the disk refuses is logged once, not once per entry", %{base: base, disk: disk} do
    {name, opts} = start_trace(base, disk)
    start_supervised!({Trace, opts})
    trace = Process.whereis(name)
    set(disk, :state, :no_open)

    log =
      capture_log(fn ->
        for n <- 1..6, do: record(name, n)
        :sys.get_state(name)
      end)

    assert Process.whereis(name) == trace
    assert lines(log, "Trace cannot open #{base}") == 1, log
  end

  test "the first entry written once there is room ends the failure, with the count dropped",
       %{base: base, disk: disk} do
    {name, opts} = start_trace(base, disk)
    start_supervised!({Trace, opts})
    record(name, 0)
    :sys.get_state(name)
    set(disk, :state, :full)

    log =
      capture_log(fn ->
        for n <- 1..3, do: record(name, n)
        :sys.get_state(name)
        set(disk, :state, :room)
        record(name, 4)
        :sys.get_state(name)
        set(disk, :state, :full)
        record(name, 5)
        :sys.get_state(name)
      end)

    assert entries(base, @today) == [0, 4]
    assert lines(log, "Trace writes again in #{base} after dropping 3 entries") == 1, log
    # The second failure is a new one, so it is logged again.
    assert lines(log, "Trace cannot write #{base}") == 2, log
  end

  test "a day's file that cannot be closed at the day's end is logged, and the new day is written",
       %{base: base, disk: disk} do
    {name, opts} = start_trace(base, disk)
    start_supervised!({Trace, opts})
    record(name, 1)
    :sys.get_state(name)
    set(disk, :state, :bad_close)
    set(disk, :today, Date.add(@today, 1))

    log =
      capture_log(fn ->
        record(name, 2)
        :sys.get_state(name)
      end)

    assert lines(log, "Trace could not close #{Path.join(base, "2026-10-30")}") == 1, log
    assert entries(base, Date.add(@today, 1)) == [2]
  end
end
