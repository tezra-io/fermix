defmodule FermixCore.PhoneCalls.Supervisor do
  @moduledoc """
  The phone-call subtree (M94 §04) as one `:rest_for_one` unit, the
  `Harness.Supervisor` shape. Independent of `Realtime.Supervisor`, the
  companion socket and the local voice switch.

  Order — `CallRegistry`, `HandoffSupervisor`, `Manager`, `CallSupervisor`,
  `DeliveryWorker`:

    * the `CallRegistry` (a unique `Registry`) finds a live call's worker by
      its call id, for the in-call controls its backend turn uses
      (`PhoneCalls.CallControls`). It is
      first so every worker can register; it raises on nothing.
    * the `HandoffSupervisor` (a `Task.Supervisor`) runs each report hand-off
      and each hang-up request off the Manager's process. It is first so a
      Manager restart does not cut a hand-off in flight; it raises on nothing.
    * a `Manager` crash restarts the `CallSupervisor` after it, ending every
      live worker first, so the restarted Manager's boot reconciliation finds
      only rows no worker owns and settles them by what they prove (a known
      session is asked to hang up; nothing is redialed). Without the order a
      restarted Manager would settle rows whose workers still run.
    * a `CallSupervisor` crash restarts only the `DeliveryWorker`; the
      surviving Manager sees each worker's DOWN and settles its row.

  Options: `:call_module` (required, the per-call worker module, see
  `PhoneCalls.Manager`'s worker contract) and `:hangup` (required, a
  `(provider_session_id -> :ok | {:error, term()})` single-attempt hang-up
  request for a known provider session), both handed to the Manager; every
  other option (`:repo`, `:now_fn`, `:delivery_opts`,
  `:continuation_dispatcher`, `:readiness`, `:config`, `:timer_enabled`, …)
  goes to the Manager and the DeliveryWorker as `Harness.Supervisor` passes
  its own. `:names` (a map of `:supervisor`, `:call_registry`,
  `:handoff_supervisor`, `:manager`, `:call_supervisor`, `:delivery_worker`)
  replaces the registered names, for a test.

  `FermixCore.Application` starts it always, the `Harness.Supervisor` way,
  so cleanup, status and recovery stay alive while phone calls are off; it is
  one of `Home.Role`'s primary-only children.
  """

  use Supervisor

  alias FermixCore.PhoneCalls.CallSupervisor
  alias FermixCore.PhoneCalls.DeliveryWorker
  alias FermixCore.PhoneCalls.Manager

  @default_names %{
    supervisor: __MODULE__,
    call_registry: FermixCore.PhoneCalls.CallRegistry,
    handoff_supervisor: FermixCore.PhoneCalls.HandoffSupervisor,
    manager: Manager,
    call_supervisor: CallSupervisor,
    delivery_worker: DeliveryWorker
  }

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    _module = Keyword.fetch!(opts, :call_module)
    _hangup = Keyword.fetch!(opts, :hangup)
    names = Map.merge(@default_names, Keyword.get(opts, :names, %{}))
    Supervisor.start_link(__MODULE__, {opts, names}, name: names.supervisor)
  end

  @impl true
  def init({opts, names}) do
    opts = Keyword.delete(opts, :names)

    manager_opts =
      Keyword.merge(opts,
        name: names.manager,
        call_supervisor: names.call_supervisor,
        call_registry: names.call_registry,
        handoff_supervisor: names.handoff_supervisor
      )

    worker_opts =
      opts
      |> Keyword.drop([
        :call_module,
        :call_args,
        :hangup,
        :readiness,
        :config,
        :continuation_dispatcher
      ])
      |> Keyword.put(:name, names.delivery_worker)

    children = [
      {Registry, keys: :unique, name: names.call_registry},
      {Task.Supervisor, name: names.handoff_supervisor},
      {Manager, manager_opts},
      {CallSupervisor, name: names.call_supervisor},
      {DeliveryWorker, worker_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
