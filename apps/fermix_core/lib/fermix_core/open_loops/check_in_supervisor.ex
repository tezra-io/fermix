defmodule FermixCore.OpenLoops.CheckInSupervisor do
  @moduledoc """
  Bounded dynamic supervisor for open-loop check-in runs (MILESTONE_78 §06).

  It starts after `OpenLoops.Scheduler` in the application's `:rest_for_one`
  list: a scheduler crash tears this supervisor and every in-flight check-in
  down before the scheduler restarts, so no run outlives the process that holds
  its claim, and the restarted scheduler's boot sweep returns the claims those
  runs held.

  `max_children: 2` is the §06 cap on concurrent check-in runs. Capacity is a
  refusal, never a queue: `{:error, :max_children}` becomes a traced skip and
  the scheduler releases the claim. Every child is `:temporary`: a finished or
  crashed run is never restarted, because its claim is the scheduler's to
  recover under a fresh decision.
  """

  use DynamicSupervisor

  alias FermixCore.OpenLoops.CheckIn

  @max_children 2

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @doc "Concurrent check-in ceiling, the supervisor's own cap (§06)."
  @spec max_children() :: pos_integer()
  def max_children, do: @max_children

  @doc """
  Starts one check-in run for an already-claimed loop.

  This is a `GenServer.call`: against a dead or shutting-down supervisor it
  exits rather than returning an error, so the caller treats a caught exit as
  the same skip as `{:error, :max_children}`.
  """
  @spec start_checkin(Supervisor.supervisor(), map()) :: DynamicSupervisor.on_start_child()
  def start_checkin(supervisor, args) when is_map(args) do
    start_checkin(supervisor, CheckIn, args)
  end

  @doc "Starts one `module` check-in child: the scheduler's module seam."
  @spec start_checkin(Supervisor.supervisor(), module(), map()) ::
          DynamicSupervisor.on_start_child()
  def start_checkin(supervisor, module, args) when is_atom(module) and is_map(args) do
    DynamicSupervisor.start_child(supervisor, {module, args})
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_children)
  end
end
