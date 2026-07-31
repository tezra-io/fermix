defmodule FermixChannels.Gateway.Stopper do
  @moduledoc """
  Emergency-stop coordinator for channel-origin execution.

  `stop_all/1` is the single halt surface the `/stop` command calls. It stops
  every active foreground turn and clears all pending FIFO work through
  `Gateway.Queue.stop_all/1`, cancels background work through
  `Gateway.WorkRegistry.stop_all/1`, and cancels every active coding-harness run
  through `FermixCore.Harness.Manager.stop_all/1` — the three explicit
  participants (design §9.2 / spec C2). It returns the counts the command reports.

  Scheduled-job runs and realtime voice are NOT reached (they have not registered
  a halt surface here), so the reply must not over-claim a full daemon halt.
  """

  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Gateway.WorkRegistry
  alias FermixCore.Harness.Manager, as: HarnessManager

  @type counts :: %{
          active_turns: non_neg_integer(),
          queued_messages: non_neg_integer(),
          background_tasks: non_neg_integer(),
          harness_runs: non_neg_integer()
        }

  @doc """
  Stop all active foreground turns, clear pending work, cancel background work,
  and cancel active coding-harness runs. Options:

    * `:queue` — the `Gateway.Queue` server (defaults to the registered name).
    * `:work_registry` — the `Gateway.WorkRegistry` server (defaults to the
      registered name).
    * `:harness` — the `Harness.Manager` server (defaults to the registered name).
  """
  @spec stop_all(keyword()) :: counts()
  def stop_all(opts \\ []) when is_list(opts) do
    queue = Keyword.get(opts, :queue, Queue)
    work_registry = Keyword.get(opts, :work_registry, WorkRegistry)
    harness = Keyword.get(opts, :harness, HarnessManager)

    %{active_stopped: active, pending_cleared: pending} = Queue.stop_all(queue)
    %{cancelled: background} = WorkRegistry.stop_all(work_registry)
    %{cancelled: harness_runs} = HarnessManager.stop_all(harness)

    %{
      active_turns: active,
      queued_messages: pending,
      background_tasks: background,
      harness_runs: harness_runs
    }
  end
end
