defmodule FermixCore.ComputerHistory.Controller do
  @moduledoc """
  Reconciles the Computer History runtime children (`Capturer` +
  `Summarizer.Scheduler`) to the feature's operative state (MILESTONE_32 §6.3).
  The always-present `Supervisor` owns an empty `DynamicSupervisor`; this
  controller is what populates it — one place that answers "should capture be
  running right now, and is it?" so enable/disable never has two code paths.

  It is the LAST child of the `Supervisor` under a `:rest_for_one` strategy, so
  a `DynamicSupervisor` crash restarts the controller too and its boot
  `reconcile` repopulates — the runtime children are never orphaned by a
  supervisor blip. On boot it reconciles once; `reconcile/1` re-runs it on every
  enable/disable act (the wizard's enable, `/history off`), and it is idempotent:
  a process already in the desired state is left untouched.

  "Operative" is `ComputerHistory.operative?/0` (enabled ∧ macOS) AND the sidecar
  binary being installed — capture cannot run without the compux sidecar, so a
  missing binary keeps the children absent (fail-closed) rather than crash-looping
  a `Capturer` that can never resolve its Port.
  """

  use GenServer

  require Logger

  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Capturer
  alias FermixCore.ComputerHistory.Summarizer.Scheduler
  alias FermixCore.ComputerHistory.Supervisor, as: CHSupervisor
  alias FermixCore.ComputerUse.SidecarInstaller

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Reconcile the runtime children to the current operative state. Idempotent, so
  every enable/disable surface can call it unconditionally.
  """
  @spec reconcile(GenServer.server()) :: :ok
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile)

  @impl true
  def init(opts) do
    state = %{
      dynamic_supervisor:
        Keyword.get(opts, :dynamic_supervisor, CHSupervisor.dynamic_supervisor()),
      operative_fun: Keyword.get(opts, :operative_fun, &ComputerHistory.operative?/0),
      installed_fun: Keyword.get(opts, :installed_fun, &SidecarInstaller.installed?/0),
      children: Keyword.get(opts, :children, default_children())
    }

    # Reconcile off `init` so boot never blocks on starting a Port-owning child.
    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    do_reconcile(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    do_reconcile(state)
    {:reply, :ok, state}
  end

  # --- reconciliation -----------------------------------------------------

  # Production children: the module IS the registered name (each `start_link`
  # defaults `name` to its module), which is how "already running?" is checked.
  defp default_children do
    [
      %{name: Capturer, spec: Capturer},
      %{name: Scheduler, spec: Scheduler}
    ]
  end

  defp do_reconcile(state) do
    want? = state.operative_fun.() and state.installed_fun.()
    Enum.each(state.children, &reconcile_child(state.dynamic_supervisor, &1, want?))
  end

  defp reconcile_child(sup, child, true), do: ensure_started(sup, child)
  defp reconcile_child(sup, child, false), do: ensure_stopped(sup, child)

  defp ensure_started(sup, %{name: name, spec: spec}) do
    case Process.whereis(name) do
      nil -> start_child(sup, name, spec)
      pid when is_pid(pid) -> :ok
    end
  end

  defp start_child(sup, name, spec) do
    case DynamicSupervisor.start_child(sup, spec) do
      {:ok, _pid} ->
        Logger.info("computer_history controller started #{inspect(name)}")

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "computer_history controller failed to start #{inspect(name)}: #{inspect(reason)}"
        )
    end
  end

  defp ensure_stopped(sup, %{name: name}) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        _ = DynamicSupervisor.terminate_child(sup, pid)
        Logger.info("computer_history controller stopped #{inspect(name)}")
    end
  end
end
