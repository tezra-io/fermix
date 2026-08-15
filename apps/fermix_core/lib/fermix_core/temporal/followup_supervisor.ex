defmodule FermixCore.Temporal.FollowupSupervisor do
  @moduledoc """
  Bounded dynamic supervisor for post-delivery follow-up runs (M30 §22.4).

  It starts after `Temporal.DeliverySupervisor` in the application's
  `:rest_for_one` list, which is load-bearing in both directions: a scheduler
  crash tears down in-flight deliveries and in-flight follow-ups together (best
  effort means exactly that), and shutdown — which terminates children in
  reverse — kills this supervisor BEFORE the delivery supervisor, so a worker
  settling a reminder mid-shutdown can find this one already gone. That is why
  `DeliveryWorker` wraps its spawn request in a caught exit.

  `max_children: 2`, deliberately below the delivery supervisor's four: a
  delivery is a seconds-long channel send, a follow-up is a model run. Capacity
  is a refusal, never a queue — `{:error, :max_children}` becomes a traced skip
  and nothing is deferred for later. Every child is `:temporary`: a follow-up
  exists only behind one already-delivered reminder, so neither completion nor a
  crash may restart it.
  """

  use DynamicSupervisor

  alias FermixCore.Temporal.Followup

  @max_children 2

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @doc "Concurrent follow-up ceiling — the supervisor's own cap (§22.4)."
  @spec max_children() :: pos_integer()
  def max_children, do: @max_children

  @doc """
  Starts one follow-up run for an already-delivered reminder.

  The caller is fire-and-forget and must treat both a returned error and a
  caught exit as a skip: this is a `GenServer.call`, so it exits rather than
  error-returns against a dead or shutting-down supervisor.
  """
  @spec start_followup(Supervisor.supervisor(), map()) :: DynamicSupervisor.on_start_child()
  def start_followup(supervisor, args) when is_map(args) do
    DynamicSupervisor.start_child(supervisor, {Followup, args})
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_children)
  end
end
