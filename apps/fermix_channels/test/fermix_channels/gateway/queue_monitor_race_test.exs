defmodule FermixChannels.Gateway.QueueMonitorRaceTest do
  @moduledoc """
  Regression guard for the monitor-after-start race in the queue.

  The OLD scheduler called `Process.monitor(pid)` AFTER
  `Task.Supervisor.start_child` returned, so a near-instant turn could finish
  before being monitored. Monitoring an already-dead pid delivers
  `{:DOWN, _, _, _, :noproc}`, which `completion_reason/1` mislabels as
  `:crashed` in the `request_complete` telemetry.

  This drives many near-instant turns (an `InstantRunner` that returns without
  blocking) through a real `Task.Supervisor`. Against the OLD code the race
  surfaces overwhelmingly — most turns are monitored only after they have
  already exited, so they emit `reason: :crashed`. Against the NEW code every
  task parks in `await_run_signal/1` until the queue sends `{self(), :run}`
  (which it only does after monitoring), so the task is always alive when
  monitored and exits `:normal`. The `crashed == 0` assertion fails closed on
  the old behavior and passes only with the handshake in place.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Gateway.Queue

  defmodule StubAgent do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:checkout_turn_state, _msg}, _from, opts) do
      {:reply, {:ok, %{test_pid: opts.test_pid}, :hit}, opts}
    end
  end

  # Instant runner: returns immediately, no blocking receive. This is the
  # near-instant turn the race needs.
  defmodule InstantRunner do
    def run(msg, _turn_state, _deliver), do: {:ok, "reply:" <> msg.content, 0}
    def commit(_msg, _turn_state, _response, _tokens), do: :ok
    def error_reply(_reason), do: "error reply"
  end

  setup do
    {:ok, %{test_pid: self()}}
  end

  defp make_msg(content, chat_id, test_pid) do
    %{
      content: content,
      sender: "user",
      channel: "telegram",
      chat_id: chat_id,
      reply_fn: fn {:text, text} -> send(test_pid, {:reply, text}) end
    }
  end

  defp attach_telemetry(event) do
    test_pid = self()
    handler_id = "race-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn evt, measurements, metadata, _config ->
        send(test_pid, {:telemetry, evt, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Drives many instant turns through a REAL Task.Supervisor. With the OLD
  # scheduler this races: occasionally the task finishes before
  # `Process.monitor(pid)` runs, the monitor returns `:noproc`, and the turn is
  # mislabeled `:crashed`. With the NEW scheduler the task parks in
  # `await_run_signal/1` until the queue sends `{self(), :run}` after monitoring,
  # so every turn is `:normal`. 200 iterations make the OLD race overwhelmingly
  # likely to surface at least once.
  @iterations 200

  test "instant turns never complete with reason :crashed", ctx do
    attach_telemetry([:fermix, :gateway, :queue, :request_complete])

    sup = start_supervised!({Task.Supervisor, []})
    agent = start_supervised!({StubAgent, test_pid: ctx.test_pid}, id: :stub_agent)

    queue =
      start_supervised!(
        {Queue,
         [
           name: :"queue_race_#{System.unique_integer([:positive])}",
           main_agent: agent,
           turn_runner: InstantRunner,
           task_supervisor: sup
         ]},
        id: :gateway_queue
      )

    capture_log(fn ->
      # Distinct chat_ids so turns run concurrently (independent conversations),
      # maximizing the start_child/monitor interleavings under load.
      for i <- 1..@iterations do
        Queue.enqueue(queue, make_msg("hello", "c#{i}", ctx.test_pid))
      end

      reasons = collect_reasons(@iterations, [])

      assert length(reasons) == @iterations,
             "only #{length(reasons)}/#{@iterations} turns completed"

      crashed = Enum.count(reasons, &(&1 == :crashed))

      assert crashed == 0,
             "#{crashed}/#{@iterations} instant turns mislabeled :crashed (spurious :noproc race)"
    end)
  end

  defp collect_reasons(0, acc), do: acc

  defp collect_reasons(remaining, acc) do
    receive do
      {:telemetry, [:fermix, :gateway, :queue, :request_complete], _m, %{reason: reason}} ->
        collect_reasons(remaining - 1, [reason | acc])
    after
      10_000 -> acc
    end
  end
end
