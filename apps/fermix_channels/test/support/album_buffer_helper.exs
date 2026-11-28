defmodule FermixChannels.Test.AlbumBufferIdle do
  @moduledoc """
  Waits until a `Gateway.AlbumBuffer` has no dispatch running and no delivery
  waiting in its lanes, and returns its state. A test that then refutes a
  dispatch (`refute_received`) checks something real: no dispatch is left in
  flight to send it later. A buffered part with its debounce still pending is
  not waited for; the returned `buffers` shows it, for the test to assert on.

  Driven by events, never by time: each round drains the buffer's mailbox
  (`:sys.get_state/1`), monitors every dispatch task its supervisor runs and
  waits for each to end. A task answers the buffer before it exits, so the next
  round sees the lanes move on to the delivery that answer started, if any.
  Bounded: a dispatch must end within 10 s, and the lanes must drain within 20
  rounds.
  """

  @dispatch_bound_ms 10_000
  @max_rounds 20

  @doc "Waits for the buffer's lanes to drain; returns the buffer's state."
  @spec await_dispatches_done(GenServer.server()) :: map()
  def await_dispatches_done(buffer), do: await_round(buffer, @max_rounds)

  defp await_round(buffer, 0),
    do: raise("album buffer #{inspect(buffer)} still dispatching after #{@max_rounds} rounds")

  defp await_round(buffer, rounds) do
    %{task_supervisor: task_supervisor} = :sys.get_state(buffer)

    case Task.Supervisor.children(task_supervisor) do
      [] ->
        drained_or_again(buffer, rounds)

      tasks ->
        Enum.each(tasks, &await_down/1)
        await_round(buffer, rounds - 1)
    end
  end

  # No task runs; a fresh read sees every answer they sent. A delivery an
  # answer started since makes another round.
  defp drained_or_again(buffer, rounds) do
    state = :sys.get_state(buffer)
    if state.tasks == %{}, do: state, else: await_round(buffer, rounds - 1)
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @dispatch_bound_ms ->
        raise "album buffer dispatch #{inspect(pid)} did not end within #{@dispatch_bound_ms} ms"
    end
  end
end
