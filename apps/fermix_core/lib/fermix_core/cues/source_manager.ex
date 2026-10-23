defmodule FermixCore.Cues.SourceManager do
  @moduledoc """
  Keeps one worker per enabled `stream` or `feed` source running under
  `Cues.SourceSupervisor`, matching `Cues.Config.sources/0` (M60 §5.3, §6.3).
  Webhook and local-push sources have no worker: the door serves them. A
  source waiting for its secret (`missing_secret`) has none either until the
  secret is stored.

  `reconcile/0` compares the configured sources with the running workers: it
  starts a worker for a new or newly enabled source, stops the worker of a
  removed or disabled one, and restarts a worker whose settings changed (the
  resolved source map differs). The config store calls it after every apply,
  so a saved change reaches the workers without a restart. The first
  reconcile runs after `init`, never inside it.

  What follows a worker's exit is decided here, not by the supervisor (every
  worker is `:temporary`):

    * a worker that stops itself (`:normal` or `:shutdown`: it gave up after
      repeated failures, its credential was refused, its source cannot be
      streamed) stays stopped until its settings change or the daemon
      restarts; it has already told the owner why;
    * a worker that crashes is restarted alone after a delay, from one second
      doubling to a minute. After five crashes within an hour it stays down,
      traced as `stopped` with reason `crashed`, and the owner is told through
      `Cues.Notices.source/4` (`:unreachable`).

  Every worker links itself to this process from its `init` (option
  `:manager`), and this process traps exits, so it sees each exit with its
  reason however soon after the start it comes (a monitor set after
  `start_child/2` returns can miss it and read `:noproc`). The link also ends
  the workers when this process dies. On start it still ends any worker left
  under the supervisor, so no source ever has two workers. Each worker
  re-reads its row when it starts.
  """

  use GenServer

  require Logger

  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Notices
  alias FermixCore.Cues.Source.Feed
  alias FermixCore.Cues.Source.Stream
  alias FermixCore.Cues.SourceSupervisor
  alias FermixCore.Cues.Telemetry

  @worker_kinds [:feed, :stream]
  @max_crashes 5
  @crash_window_ms 3_600_000
  @first_restart_ms 1_000
  @max_restart_ms 60_000
  # 1 s doubled six times passes the one-minute cap.
  @max_restart_shift 6

  @type worker_status :: pid() | :stopped | :restarting

  @doc """
  Starts the manager. Options: `:name` (default `#{inspect(__MODULE__)}`),
  `:supervisor` (default `Cues.SourceSupervisor`), `:sources` (zero-arity,
  default `Cues.Config.sources/0`), `:workers` (kind to module, default
  `%{feed: Cues.Source.Feed, stream: Cues.Source.Stream}`), `:worker_opts`
  (added to every worker's options), `:schedule` (`(message, ms) -> term`),
  `:monotonic_ms` (zero-arity), `:notify` (default `Cues.Notices.source/4`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Asks the manager to match the workers to the configured sources. A no-op
  when no manager runs (cues off, a tree-less process, boot before the tree).
  """
  @spec reconcile(GenServer.server()) :: :ok
  def reconcile(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, :reconcile)
    end
  end

  @doc "Each managed source's worker: its pid, `:stopped` or `:restarting`."
  @spec workers(GenServer.server()) :: %{optional(String.t()) => worker_status()}
  def workers(server \\ __MODULE__), do: GenServer.call(server, :workers)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      supervisor: Keyword.get(opts, :supervisor, SourceSupervisor),
      sources: Keyword.get(opts, :sources, &Config.sources/0),
      modules: Keyword.get(opts, :workers, %{feed: Feed, stream: Stream}),
      worker_opts: Keyword.get(opts, :worker_opts, []),
      schedule: Keyword.get(opts, :schedule, &send_after/2),
      monotonic_ms:
        Keyword.get(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
      notify: Keyword.get(opts, :notify, &Notices.source/4),
      running: %{},
      stopped: %{},
      restarting: %{},
      next_token: 0
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    end_orphans(state.supervisor)
    {:noreply, run_reconcile(state)}
  end

  @impl true
  def handle_cast(:reconcile, state), do: {:noreply, run_reconcile(state)}

  @impl true
  def handle_call(:workers, _from, state) do
    running = Map.new(state.running, fn {ref, entry} -> {ref, entry.pid} end)
    stopped = Map.new(state.stopped, fn {ref, _settings} -> {ref, :stopped} end)
    restarting = Map.new(state.restarting, fn {ref, _entry} -> {ref, :restarting} end)
    {:reply, running |> Map.merge(stopped) |> Map.merge(restarting), state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    case Enum.find(state.running, fn {_ref, entry} -> entry.pid == pid end) do
      # A worker this process stopped itself, or one from before a restart.
      nil -> {:noreply, state}
      {ref, entry} -> {:noreply, worker_down(drop_running(state, ref), ref, entry, reason)}
    end
  end

  def handle_info({:restart, ref, token}, state) do
    case Map.fetch(state.restarting, ref) do
      {:ok, %{token: ^token} = entry} ->
        state = %{state | restarting: Map.delete(state.restarting, ref)}
        {:noreply, start_worker(state, entry.settings, entry.crashes)}

      _stale ->
        {:noreply, state}
    end
  end

  # --- reconcile ---------------------------------------------------------------

  defp run_reconcile(state) do
    desired = desired(state.sources.())

    state
    |> stop_changed(desired)
    |> forget_changed(desired)
    |> start_missing(desired)
  end

  # A source waiting for its secret (`missing_secret`) runs no worker until the
  # secret is stored, which changes its settings and so starts it here.
  defp desired(sources) do
    for %{ref: ref, kind: kind, enabled?: true} = source <- sources,
        kind in @worker_kinds,
        Map.get(source, :missing_secret) == nil,
        into: %{},
        do: {ref, source}
  end

  defp stop_changed(state, desired) do
    Enum.reduce(state.running, state, fn {ref, entry}, acc ->
      if Map.get(desired, ref) == entry.settings, do: acc, else: stop_worker(acc, ref, entry)
    end)
  end

  # The entry goes first, so the worker's exit signal finds no entry.
  defp stop_worker(state, ref, entry) do
    state = drop_running(state, ref)

    case DynamicSupervisor.terminate_child(state.supervisor, entry.pid) do
      :ok -> :ok
      # It exited between the reconcile and here; there is nothing to stop.
      {:error, :not_found} -> :ok
    end

    state
  end

  # A stopped worker, or one waiting to restart, is forgotten once its source's
  # settings change or it is no longer wanted, so the next step starts afresh.
  defp forget_changed(state, desired) do
    same? = fn ref, settings -> Map.get(desired, ref) == settings end

    %{
      state
      | stopped: Map.filter(state.stopped, fn {ref, settings} -> same?.(ref, settings) end),
        restarting:
          Map.filter(state.restarting, fn {ref, entry} -> same?.(ref, entry.settings) end)
    }
  end

  defp start_missing(state, desired) do
    Enum.reduce(desired, state, fn {ref, settings}, acc ->
      if managed?(acc, ref), do: acc, else: start_worker(acc, settings, [])
    end)
  end

  defp managed?(state, ref) do
    Map.has_key?(state.running, ref) or Map.has_key?(state.stopped, ref) or
      Map.has_key?(state.restarting, ref)
  end

  defp start_worker(state, settings, crashes) do
    module = Map.fetch!(state.modules, settings.kind)
    opts = [source: settings, manager: self()] ++ state.worker_opts
    spec = Supervisor.child_spec({module, opts}, restart: :temporary)

    case DynamicSupervisor.start_child(state.supervisor, spec) do
      {:ok, pid} ->
        entry = %{pid: pid, settings: settings, crashes: crashes}
        %{state | running: Map.put(state.running, settings.ref, entry)}

      :ignore ->
        %{state | stopped: Map.put(state.stopped, settings.ref, settings)}

      {:error, reason} ->
        crashed(state, settings, crashes, {:start_failed, reason})
    end
  end

  defp end_orphans(supervisor) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid) do
      case DynamicSupervisor.terminate_child(supervisor, pid) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    end
  end

  # --- exits ---------------------------------------------------------------------

  defp worker_down(state, ref, entry, reason) when reason in [:normal, :shutdown] do
    Logger.info("Cue source #{ref} stopped; it starts again when its settings change")
    %{state | stopped: Map.put(state.stopped, ref, entry.settings)}
  end

  defp worker_down(state, ref, entry, {:shutdown, _detail}),
    do: worker_down(state, ref, entry, :shutdown)

  defp worker_down(state, _ref, entry, reason),
    do: crashed(state, entry.settings, entry.crashes, reason)

  defp crashed(state, settings, crashes, reason) do
    now = state.monotonic_ms.()
    recent = [now | Enum.filter(crashes, &(now - &1 < @crash_window_ms))]
    Logger.error("Cue source #{settings.ref} worker failed: #{inspect(reason)}")

    if length(recent) >= @max_crashes,
      do: give_up(state, settings, recent, reason),
      else: schedule_restart(state, settings, recent)
  end

  defp schedule_restart(state, settings, crashes) do
    token = state.next_token + 1
    shift = min(length(crashes) - 1, @max_restart_shift)
    delay = min(@first_restart_ms * Integer.pow(2, shift), @max_restart_ms)
    state.schedule.({:restart, settings.ref, token}, delay)
    entry = %{settings: settings, token: token, crashes: crashes}
    %{state | next_token: token, restarting: Map.put(state.restarting, settings.ref, entry)}
  end

  defp give_up(state, settings, crashes, reason) do
    ref = settings.ref

    Telemetry.source(:stopped, %{
      source_ref: ref,
      kind: settings.kind,
      status: "stopped",
      reason: "crashed",
      attempt: length(crashes),
      result: {:error, crash_class(reason)}
    })

    Logger.error(
      "Cue source #{ref} crashed #{length(crashes)} times within an hour; left stopped"
    )

    notify(state, ref, %{reason: "crashed", crashes: length(crashes)})
    %{state | stopped: Map.put(state.stopped, ref, settings)}
  end

  defp notify(state, ref, data) do
    case state.notify.(ref, :unreachable, data, []) do
      {:error, reason} ->
        Logger.error("Cue source #{ref}: the owner could not be told: #{inspect(reason)}")

      _sent ->
        :ok
    end
  end

  # Only the head of the reason reaches the trace (`Cues.Telemetry` derives the
  # class from it); the whole reason is in the log line above.
  defp crash_class({:start_failed, _reason}), do: :start_failed
  defp crash_class(_reason), do: :crashed

  defp drop_running(state, ref), do: %{state | running: Map.delete(state.running, ref)}

  defp send_after(message, ms), do: Process.send_after(self(), message, ms)
end
