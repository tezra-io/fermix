defmodule FermixChannels.Gateway.WorkRegistry do
  @moduledoc """
  Tracks background work items started by `/background` (and a backgrounded
  `/ultra`). Spawns each item's runner under `WorkSupervisor`, monitors it, and
  records channel-visible status for `/tasks` and `/stop`.

  Stores only neutral metadata (work id, command, profile, source, a short prompt
  preview) — never the full prompt or the result body, so `/tasks` has nothing to
  leak by construction (§17.7). Completed/failed/cancelled entries are retained
  under a small bounded cap; running entries are never evicted, so concurrently
  running work carries its own separate ceiling — a start past it is refused,
  never queued.

  The runner is a 0-arity thunk supplied by the command layer: the registry owns
  spawn → monitor → status, not the work itself, so it stays independent of
  `FermixCore.Agents.BackgroundRun`.
  """

  use GenServer

  require Logger

  alias FermixChannels.Gateway.WorkId

  @default_work_supervisor FermixChannels.Gateway.WorkSupervisor
  @max_terminal 50

  # Ceiling on *concurrently running* work — a different quantity from
  # @max_terminal, which only bounds how much finished history is retained.
  # Running entries are never evicted and each one is a detached agent turn
  # spending the owner's provider budget, so without this the registry grows
  # unbounded under repeated `/background`. Over the cap `start/2` refuses
  # loudly with the cap in the reason; it never queues and never evicts a
  # running item to make room.
  @max_running 8

  @type status :: :running | :completed | :failed | :cancelled

  @type request :: %{
          required(:run) => (String.t() -> any()),
          optional(:command) => String.t(),
          optional(:profile) => atom(),
          optional(:channel) => String.t(),
          optional(:conversation_key) => term(),
          optional(:prompt_preview) => String.t()
        }

  # Public shape returned by `list/2` — `conversation_key` is internal (used only
  # to scope `/tasks`) and is dropped before it leaves the registry.
  @type entry :: %{
          work_id: String.t(),
          command: String.t(),
          profile: atom(),
          channel: String.t() | nil,
          prompt_preview: String.t(),
          status: status(),
          started_monotonic_ms: integer()
        }

  # --- Client ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a background work item; returns its work id. Refuses with
  `{:error, {:max_running_work, max}}` when `max` items are already running —
  the caller is expected to surface the cap, not to retry.
  """
  @spec start(GenServer.server(), request()) :: {:ok, String.t()} | {:error, term()}
  def start(server \\ __MODULE__, request) when is_map(request) do
    GenServer.call(server, {:start, request})
  end

  @doc """
  List tracked work items for `scope` — a conversation key, or `:all`. Running
  items first, then most-recent terminal. Scoping keeps `/tasks` showing only
  work started from the requesting conversation (§17.7).
  """
  @spec list(GenServer.server(), :all | term()) :: [entry()]
  def list(server \\ __MODULE__, scope \\ :all) do
    GenServer.call(server, {:list, scope})
  end

  @doc "Cancel every running work item. Returns the count cancelled."
  @spec stop_all(GenServer.server()) :: %{cancelled: non_neg_integer()}
  def stop_all(server \\ __MODULE__) do
    GenServer.call(server, :stop_all)
  end

  # --- Server ---

  @impl true
  def init(opts) do
    state = %{
      work_supervisor: Keyword.get(opts, :work_supervisor, @default_work_supervisor),
      max_terminal: Keyword.get(opts, :max_terminal, @max_terminal),
      work: %{},
      monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start, %{run: run} = request}, _from, state) when is_function(run, 1) do
    do_start(state, request, run)
  end

  def handle_call({:start, _request}, _from, state) do
    {:reply, {:error, :missing_run}, state}
  end

  def handle_call({:list, scope}, _from, state) do
    {:reply, public_list(state, scope), state}
  end

  def handle_call(:stop_all, _from, state) do
    {state, count} = cancel_running(state)
    {:reply, %{cancelled: count}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {work_id, monitors} ->
        state =
          %{state | monitors: monitors}
          |> finish(work_id, terminal_status(reason))
          |> evict_terminal()

        {:noreply, state}
    end
  end

  # --- internals ---

  defp do_start(state, request, run) do
    case running_count(state) do
      count when count >= @max_running ->
        {:reply, {:error, {:max_running_work, @max_running}}, state}

      _below_cap ->
        spawn_work(state, request, run)
    end
  end

  defp running_count(state) do
    Enum.count(state.work, fn {_work_id, entry} -> entry.status == :running end)
  end

  defp spawn_work(state, request, run) do
    work_id = WorkId.generate()
    owner = self()

    # Start the task BLOCKED on a run signal so the monitor is installed before
    # the thunk runs. Otherwise a fast job can exit before `Process.monitor/1`,
    # whose `:noproc` `:DOWN` would mis-record a successful job as `:failed`.
    fun = fn ->
      await_run_signal(owner)
      run.(work_id)
    end

    case Task.Supervisor.start_child(state.work_supervisor, fun) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        send(pid, {owner, :run})
        entry = build_entry(work_id, request, pid, ref)

        state =
          state
          |> put_in([:work, work_id], entry)
          |> put_in([:monitors, ref], work_id)

        {:reply, {:ok, work_id}, state}

      {:error, reason} ->
        Logger.error("Failed to start background work: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # Block until the registry has installed its monitor and released us. If the
  # registry dies first, exit cleanly so the task cannot leak.
  defp await_run_signal(owner) do
    owner_ref = Process.monitor(owner)

    receive do
      {^owner, :run} -> Process.demonitor(owner_ref, [:flush])
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> exit(:normal)
    end
  end

  defp build_entry(work_id, request, pid, ref) do
    %{
      work_id: work_id,
      command: Map.get(request, :command, "background"),
      profile: Map.get(request, :profile, :normal),
      channel: Map.get(request, :channel),
      conversation_key: Map.get(request, :conversation_key),
      prompt_preview: preview(Map.get(request, :prompt_preview, "")),
      status: :running,
      started_monotonic_ms: System.monotonic_time(:millisecond),
      pid: pid,
      ref: ref
    }
  end

  # Short preview only — never the full prompt (structural redaction, §17.7).
  defp preview(text) when is_binary(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 80)
  end

  defp preview(_text), do: ""

  defp cancel_running(state) do
    {state, count} =
      Enum.reduce(state.work, {state, 0}, fn
        {work_id, %{status: :running, pid: pid, ref: ref}}, {acc, count} ->
          # Flush the monitor so the killed task's :DOWN never arrives — but that
          # also skips the :DOWN path's eviction, so evict explicitly below.
          Process.demonitor(ref, [:flush])
          Task.Supervisor.terminate_child(acc.work_supervisor, pid)

          acc =
            acc
            |> update_in([:monitors], &Map.delete(&1, ref))
            |> mark(work_id, :cancelled)

          {acc, count + 1}

        {_work_id, _entry}, {acc, count} ->
          {acc, count}
      end)

    {evict_terminal(state), count}
  end

  defp finish(state, work_id, status) do
    case get_in(state, [:work, work_id]) do
      %{status: :running} -> mark(state, work_id, status)
      _terminal_or_missing -> state
    end
  end

  defp mark(state, work_id, status) do
    update_in(state, [:work, work_id], fn entry ->
      entry |> Map.put(:status, status) |> Map.drop([:pid, :ref])
    end)
  end

  defp terminal_status(:normal), do: :completed
  defp terminal_status(_reason), do: :failed

  # Keep all running + the most recent `max_terminal` terminal entries.
  defp evict_terminal(state) do
    drop =
      state.work
      |> Enum.filter(fn {_id, entry} -> entry.status != :running end)
      |> Enum.sort_by(fn {_id, entry} -> entry.started_monotonic_ms end, :desc)
      |> Enum.drop(state.max_terminal)
      |> Enum.map(fn {id, _entry} -> id end)

    update_in(state.work, &Map.drop(&1, drop))
  end

  defp public_list(state, scope) do
    state.work
    |> Map.values()
    |> Enum.filter(&in_scope?(&1, scope))
    |> Enum.map(&Map.drop(&1, [:pid, :ref, :conversation_key]))
    |> Enum.sort_by(&{status_rank(&1.status), -&1.started_monotonic_ms})
  end

  defp in_scope?(_entry, :all), do: true
  defp in_scope?(entry, scope), do: Map.get(entry, :conversation_key) == scope

  defp status_rank(:running), do: 0
  defp status_rank(_terminal), do: 1
end
