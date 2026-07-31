defmodule FermixCore.Harness.Supervisor do
  @moduledoc """
  Supervises the coding-harness local rail as one `:rest_for_one` unit so a
  crash tears the rail down in dependency order (design §6.4, spec §5).

  Order — `Manager`, `RunSupervisor`, `DeliveryWorker`:

    * a `Manager` crash restarts the `RunSupervisor` (and `DeliveryWorker`) that
      follow it, sweeping every live `Harness.Run` first — so the restarted
      Manager's boot reconciliation only ever finds genuinely dead rows. Without
      this ordering a Manager-only restart would orphan live runs: their vendor
      CLIs keep executing and report to a stale manager pid, their rows get
      falsely terminalized `interrupted`, and their released workspace locks let a
      second run into a still-running worktree.
    * a `RunSupervisor` crash restarts only the `DeliveryWorker` after it; the
      surviving `Manager` sees each killed run's DOWN and terminalizes it
      `failed/:run_crashed` (its monitor map is intact).

  Always started, even with the feature disabled: boot reconciliation and the
  delivery-outbox drain must finish in-flight work regardless of `enabled?`. The
  worker timer seam (`opts`) rides through to `Manager`/`DeliveryWorker`;
  `RunSupervisor` takes no options.
  """

  use Supervisor

  alias FermixCore.Harness.DeliveryWorker
  alias FermixCore.Harness.Manager
  alias FermixCore.Harness.RunSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Manager, opts},
      RunSupervisor,
      {DeliveryWorker, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
