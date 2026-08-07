defmodule FermixCore.Temporal.DeliverySupervisor do
  @moduledoc """
  Bounded dynamic supervisor for reminder delivery workers (M30 §6.3).

  It starts after `Temporal.Scheduler` in the application's `:rest_for_one` list,
  which is load-bearing: a scheduler crash terminates every later child — this
  supervisor and its workers — before the scheduler restarts, so **no delivery
  worker can outlive the scheduler**. That single invariant is what lets claims
  be serialized in one process without lease tokens or fenced settlement
  (§19.10).

  `max_children` is the final OTP authority on delivery concurrency; the
  scheduler's capacity precheck is only an optimization that avoids claiming rows
  it cannot start. Every child is `:temporary`, so a completed or crashed send is
  never restarted outside a fresh durable claim.
  """

  use DynamicSupervisor

  @max_children 4

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @doc "Concurrent delivery ceiling — the supervisor's own cap (§6.3)."
  @spec max_children() :: pos_integer()
  def max_children, do: @max_children

  @doc "Starts one `worker_module` delivery child for an already-claimed row."
  @spec start_delivery(Supervisor.supervisor(), module(), map()) ::
          DynamicSupervisor.on_start_child()
  def start_delivery(supervisor, worker_module, args)
      when is_atom(worker_module) and is_map(args) do
    DynamicSupervisor.start_child(supervisor, {worker_module, args})
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_children)
  end
end
