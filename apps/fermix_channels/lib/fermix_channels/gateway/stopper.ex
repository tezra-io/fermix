defmodule FermixChannels.Gateway.Stopper do
  @moduledoc """
  Emergency-stop coordinator for channel-origin execution.

  `stop_all/1` is the single halt surface the `/stop` command calls. It stops
  every active foreground turn and clears all pending FIFO work through
  `Gateway.Queue.stop_all/1`, returning the counts the command reports.

  Both foreground turns (`Gateway.Queue`) and background work
  (`Gateway.WorkRegistry`) are halted. Scheduled-job runs and realtime voice are
  NOT reached in v1 (they have not registered a halt surface here), so the reply
  must not over-claim a full daemon halt.
  """

  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Gateway.WorkRegistry

  @type counts :: %{
          active_turns: non_neg_integer(),
          queued_messages: non_neg_integer(),
          background_tasks: non_neg_integer()
        }

  @doc """
  Stop all active foreground turns, clear pending work, and cancel background
  work. Options:

    * `:queue` — the `Gateway.Queue` server (defaults to the registered name).
    * `:work_registry` — the `Gateway.WorkRegistry` server (defaults to the
      registered name).
  """
  @spec stop_all(keyword()) :: counts()
  def stop_all(opts \\ []) when is_list(opts) do
    queue = Keyword.get(opts, :queue, Queue)
    work_registry = Keyword.get(opts, :work_registry, WorkRegistry)

    %{active_stopped: active, pending_cleared: pending} = Queue.stop_all(queue)
    %{cancelled: background} = WorkRegistry.stop_all(work_registry)

    %{active_turns: active, queued_messages: pending, background_tasks: background}
  end
end
