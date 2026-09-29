defmodule FermixChannels.Gateway.QueueSupervisor do
  @moduledoc """
  Ties every turn task's life to the `Gateway.Queue` that started it.

  Two children, `:one_for_all`, in this order:

  1. the `Task.Supervisor` every turn task runs under,
  2. the Queue, handed that supervisor as its `:task_supervisor`.

  When the Queue dies, this supervisor first terminates the task supervisor,
  and with it every turn the dead Queue started, then restarts both in order.
  A restarted Queue starts from empty state, so without this a surviving turn
  would keep running tools, delivering and committing beside the new Queue's
  turn for the same conversation, where `/stop` cannot reach it.

  The killed turns, and the messages the dead Queue held waiting, get no
  `turn_result_fn` outcome. A consumer that must not wait forever watches the
  Queue process instead: `Acp.Peer` answers the prompt as a failed turn, and
  mobile's `RequestCoordinator` releases the request.

  Options:

    * `:name` — this supervisor (default: this module).
    * `:turn_tasks` — the task supervisor (default
      `FermixChannels.Gateway.TurnTasks`).
    * `:queue` — the Queue's options; its `:task_supervisor` is always
      `:turn_tasks`.
  """

  use Supervisor

  alias FermixChannels.Gateway.Queue

  @turn_tasks FermixChannels.Gateway.TurnTasks

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    turn_tasks = Keyword.get(opts, :turn_tasks, @turn_tasks)
    queue_opts = opts |> Keyword.get(:queue, []) |> Keyword.put(:task_supervisor, turn_tasks)

    children = [
      {Task.Supervisor, name: turn_tasks},
      {Queue, queue_opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
