defmodule FermixCore.ComputerHistory.Controller do
  @moduledoc """
  Reconciles the Computer History runtime children (`Capturer` +
  `Summarizer.Scheduler`) to the feature's operative state (MILESTONE_32 §6.3).
  The always-present `Supervisor` owns an empty `DynamicSupervisor`; this
  controller is what populates it — the one place that decides "should capture
  be running right now, and is it?" so enable/disable never has two code paths.
  The `Capturer` re-reads the same resolver (`ComputerHistory.operative?/0`) at
  every start and declines (`:ignore`) while the feature is off, so a restart
  that races a disable cannot bring capture back.

  It follows the `DynamicSupervisor` in the `Supervisor`'s `:rest_for_one`
  order, so a `DynamicSupervisor` crash restarts the controller too and its boot
  `reconcile` repopulates — the runtime children are never orphaned by a
  supervisor blip. On boot it reconciles once; `reconcile/2` re-runs it only
  from `/history off` (an enable takes effect at the next boot), and it is
  idempotent: a process already in the desired state is left untouched.

  "Operative" is `ComputerHistory.operative?/0` (enabled ∧ macOS) AND the sidecar
  binary being installed — capture cannot run without the compux sidecar, so a
  missing binary keeps the children absent (fail-closed) rather than crash-looping
  a `Capturer` that can never resolve its Port — AND this machine's store having
  opened (`Spool.status/1`): a store that did not keeps the recorder off.

  On a computer whose home is a server (the device role, `FermixCore.Home.Role`)
  both run while history records there: the recorder writes this machine's
  own store, and the scheduler sends its sittings and its report to the home,
  which summarizes them (M97 §8.1).
  """

  use GenServer

  require Logger

  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Capturer
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.ComputerHistory.Submission
  alias FermixCore.ComputerHistory.Summarizer.Scheduler
  alias FermixCore.ComputerHistory.Supervisor, as: CHSupervisor
  alias FermixCore.ComputerUse.SidecarInstaller
  alias FermixCore.Home.Role

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # How long a reconcile call waits. A stop waits for each runtime child to exit,
  # and the DynamicSupervisor gives each the default 5 s shutdown before a kill
  # (the Capturer's terminate/2 flush is the slow one), so the call outlasts both
  # children's shutdowns: only a wedged Controller makes the caller give up.
  @reconcile_timeout_ms 15_000

  @doc """
  Reconcile the runtime children to the current operative state. Idempotent, so
  every enable/disable surface can call it unconditionally. Returns once every stop
  is done and every start attempted; the call exits if that takes over `timeout`.
  """
  @spec reconcile(GenServer.server(), non_neg_integer()) :: :ok
  def reconcile(server \\ __MODULE__, timeout \\ @reconcile_timeout_ms)
      when is_integer(timeout) and timeout >= 0, do: GenServer.call(server, :reconcile, timeout)

  @impl true
  def init(opts) do
    state = %{
      dynamic_supervisor:
        Keyword.get(opts, :dynamic_supervisor, CHSupervisor.dynamic_supervisor()),
      operative_fun: Keyword.get(opts, :operative_fun, &ComputerHistory.operative?/0),
      installed_fun: Keyword.get(opts, :installed_fun, &SidecarInstaller.installed?/0),
      spool: Keyword.get(opts, :spool),
      children:
        Keyword.get_lazy(opts, :children, fn ->
          role = Keyword.get_lazy(opts, :engine_role, &Role.current/0)
          default_children(role, Keyword.take(opts, [:timer_enabled, :spool]))
        end)
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
  # `want` says when each runs: the recorder while history records here, the
  # scheduler always on the home (its roll-up) and while history records on a
  # computer (its sittings, sent over the link). Public (@doc false) so the
  # role's filter is pinned without a running capture.
  @doc false
  @spec default_children(Role.role(), keyword()) :: [
          %{name: module(), spec: module() | {module(), keyword()}, want: :recording | :always}
        ]
  def default_children(role, opts \\ []) when role in [:primary, :device] and is_list(opts) do
    [
      %{name: Capturer, spec: Capturer, want: :recording},
      %{
        name: Scheduler,
        spec: {Scheduler, scheduler_opts(role, opts)},
        want: scheduler_want(role)
      }
    ]
    |> Enum.filter(&(Role.children([&1.name], role) != []))
  end

  defp scheduler_want(:primary), do: :always
  defp scheduler_want(:device), do: :recording

  # Where a sitting goes (M97 §8.1): on the home, in process; from a computer,
  # over the link (`FermixChannels.Desktop.HistoryUplink`, the channels app's,
  # named at run time), with the report of its recorder (§8.5). A computer
  # keeps no notes, so it has no roll-up. `:spool` is this machine's store, nil
  # where it keeps none (no recorder).
  defp scheduler_opts(:primary, opts),
    do: Keyword.put(opts, :uplink, &home_uplink/1)

  defp scheduler_opts(:device, opts),
    do: Keyword.merge(opts, uplink: &device_uplink/1, report: &device_report/1, repo: nil)

  @doc false
  @spec home_uplink(map()) :: {:ok, Submission.answer()}
  def home_uplink(payload) when is_map(payload), do: {:ok, Submission.accept("", payload)}

  @doc false
  @spec device_uplink(map()) :: {:ok, Submission.answer()} | {:error, term()}
  def device_uplink(payload) when is_map(payload),
    do: apply(Module.concat([FermixChannels, Desktop, HistoryUplink]), :submit, [payload])

  @doc false
  @spec device_report(map()) :: :ok | {:error, term()}
  def device_report(report) when is_map(report),
    do: apply(Module.concat([FermixChannels, Desktop, HistoryUplink]), :report, [report])

  defp do_reconcile(state) do
    recording? = state.operative_fun.() and state.installed_fun.() and store_open?(state.spool)

    Enum.each(
      state.children,
      &reconcile_child(state.dynamic_supervisor, &1, want?(&1, recording?))
    )
  end

  # Nothing records into a store that did not open (M97 §8.1): `Spool` stays up
  # holding why, which `/history status` says. A rail with no store (no
  # recorder on this system) never records, so it has nothing to ask.
  defp store_open?(nil), do: true
  defp store_open?(spool), do: Spool.status(server: spool) == :open

  defp want?(%{want: :always}, _recording?), do: true
  defp want?(_child, recording?), do: recording?

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

      # The child's own init found the feature off (a disable raced this start).
      :ignore ->
        Logger.info("computer_history controller: #{inspect(name)} declined to start")

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
        log_stop(name, DynamicSupervisor.terminate_child(sup, pid))
    end
  end

  defp log_stop(name, :ok),
    do: Logger.info("computer_history controller stopped #{inspect(name)}")

  # The pid `whereis` returned exited after the lookup, so the DynamicSupervisor
  # no longer has it; a restart after the disable declines (see the moduledoc).
  defp log_stop(name, {:error, :not_found}),
    do: Logger.info("computer_history controller: #{inspect(name)} already gone")
end
