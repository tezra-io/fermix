defmodule FermixCore.Management.Doctor do
  @moduledoc """
  Asynchronous bounded Doctor sessions behind `doctor.start|get|cancel`
  (M34 §2, §5).

  A network check can take tens of seconds; holding a management request open
  that long would make the app's socket client indistinguishable from a hung
  daemon. So a run is a *session*: `start/1` mints a `session_id` and returns
  immediately, `get/2` reports progress, and `cancel/2` stops it.

  Every bound is explicit and monotonic:

  - one whole-run budget per scope — local 10s, network 30s — after which the
    task is terminated and the unrun checks finish as `timed_out`;
  - at most two concurrent sessions, beyond which `start/1` is `:busy`;
  - at most eight retained finished sessions, and none older than five minutes.

  Checks come from `FermixCore.Management.Doctor.Descriptor`, which adapts
  `Fermix.CLI.Doctor.Checks` — the sole source of check logic.
  """

  use GenServer

  alias FermixCore.Management.Doctor.Descriptor
  alias FermixCore.Management.Doctor.Session
  alias FermixCore.Management.Telemetry

  require Logger

  @local_budget_ms 10_000
  @network_budget_ms 30_000
  @max_concurrent 2
  @max_retained 8
  @retention_ms 300_000
  @session_id_bytes 9
  @scopes [:local, :network]
  @terminal [:completed, :cancelled, :timed_out, :failed]

  @type scope :: :local | :network
  @type view :: %{String.t() => term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The whole-run budget for a scope."
  @spec budget_ms(scope()) :: pos_integer()
  def budget_ms(:local), do: @local_budget_ms
  def budget_ms(:network), do: @network_budget_ms

  @spec max_concurrent_sessions() :: pos_integer()
  def max_concurrent_sessions, do: @max_concurrent

  @spec max_retained_sessions() :: pos_integer()
  def max_retained_sessions, do: @max_retained

  @doc "Starts one bounded session. `:busy` when the concurrency bound is reached."
  @spec start(keyword()) :: {:ok, view()} | {:error, :busy | :invalid_scope}
  def start(opts \\ []) when is_list(opts) do
    GenServer.call(server(opts), {:start, opts})
  end

  @spec get(String.t(), keyword()) :: {:ok, view()} | {:error, :unknown_session}
  def get(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    GenServer.call(server(opts), {:get, session_id})
  end

  @spec cancel(String.t(), keyword()) :: {:ok, view()} | {:error, :unknown_session}
  def cancel(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    GenServer.call(server(opts), {:cancel, session_id})
  end

  @doc "The most recently finished session, for `diagnostics.build`."
  @spec latest(keyword()) :: {:ok, view()} | {:error, :none}
  def latest(opts \\ []) when is_list(opts) do
    GenServer.call(server(opts), :latest)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       sessions: %{},
       order: [],
       task_refs: %{},
       task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
       clock: Keyword.get(opts, :clock, &monotonic_ms/0)
     }}
  end

  @impl true
  def handle_call({:start, opts}, _from, state) do
    scope = Keyword.get(opts, :scope, :local)

    cond do
      scope not in @scopes -> {:reply, {:error, :invalid_scope}, state}
      running_count(state) >= @max_concurrent -> {:reply, {:error, :busy}, state}
      true -> start_session(state, scope, opts)
    end
  end

  def handle_call({:get, session_id}, _from, state) do
    {:reply, fetch_view(state, session_id), state}
  end

  def handle_call({:cancel, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :running} = session} -> cancel_session(state, session)
      {:ok, session} -> {:reply, {:ok, view(session)}, state}
      :error -> {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call(:latest, _from, state) do
    {:reply, latest_view(state), state}
  end

  @impl true
  def handle_info({:doctor_check, session_id, index, result}, state) do
    {:noreply, put_result(state, session_id, index, result)}
  end

  def handle_info({:deadline, session_id}, state) do
    {:noreply, terminate_session(state, session_id, :timed_out)}
  end

  def handle_info({ref, :ok}, state) when is_reference(ref) do
    {:noreply, complete_task(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    {:noreply, task_down(state, ref, reason)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_session(state, scope, opts) do
    specs = Keyword.get(opts, :descriptors) || Descriptor.catalog(scope)
    budget_ms = Keyword.get(opts, :budget_ms, budget_ms(scope))
    session_id = mint_session_id()
    meta = %{session_id: session_id, scope: scope, budget_ms: budget_ms}

    Telemetry.session_start(meta, length(specs))

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, Session, :run, [
        specs,
        [
          owner: self(),
          session_id: session_id,
          deadline_mono: state.clock.() + budget_ms,
          clock: state.clock
        ]
      ])

    session = %{
      session_id: session_id,
      scope: scope,
      budget_ms: budget_ms,
      specs: specs,
      results: %{},
      status: :running,
      started_at: DateTime.utc_now(),
      started_mono: state.clock.(),
      finished_at: nil,
      finished_mono: nil,
      duration_ms: 0,
      meta: meta,
      task: task,
      deadline_timer: Process.send_after(self(), {:deadline, session_id}, budget_ms)
    }

    state = %{
      state
      | sessions: Map.put(state.sessions, session_id, session),
        order: state.order ++ [session_id],
        task_refs: Map.put(state.task_refs, task.ref, session_id)
    }

    {:reply, {:ok, view(session)}, prune(state)}
  end

  defp cancel_session(state, session) do
    state = terminate_session(state, session.session_id, :cancelled)
    {:reply, fetch_view(state, session.session_id), state}
  end

  defp put_result(state, session_id, index, result) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :running} = session} ->
        session = %{session | results: Map.put(session.results, index, result)}
        %{state | sessions: Map.put(state.sessions, session_id, session)}

      _finished_or_unknown ->
        state
    end
  end

  defp complete_task(state, ref) do
    case Map.fetch(state.task_refs, ref) do
      {:ok, session_id} ->
        Process.demonitor(ref, [:flush])
        state |> forget_ref(ref) |> finish(session_id, :completed)

      :error ->
        state
    end
  end

  defp task_down(state, ref, reason) do
    case Map.fetch(state.task_refs, ref) do
      {:ok, session_id} -> down_session(state, ref, session_id, reason)
      :error -> state
    end
  end

  defp down_session(state, ref, session_id, reason) do
    session = Map.fetch!(state.sessions, session_id)
    Telemetry.session_error(session.meta, :task_down, reason)
    Logger.error("Doctor session #{session_id} failed: #{inspect(reason)}")
    state |> forget_ref(ref) |> finish(session_id, :failed)
  end

  # Stops a running session's task and closes it in the given terminal state.
  # A session that already finished is left exactly as it is.
  defp terminate_session(state, session_id, status) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :running} = session} -> stop_task(state, session, status)
      _finished_or_unknown -> state
    end
  end

  defp stop_task(state, session, status) do
    :ok = drop_task(state.task_supervisor, session.task.pid)
    Process.demonitor(session.task.ref, [:flush])

    state
    |> forget_ref(session.task.ref)
    |> finish(session.session_id, status)
  end

  # `:not_found` means the task exited between the deadline firing and this
  # call — the session still closes in the requested terminal state.
  defp drop_task(task_supervisor, pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp finish(state, session_id, requested) when requested in @terminal do
    session = Map.fetch!(state.sessions, session_id)
    status = resolve_status(requested, session)
    _ = Process.cancel_timer(session.deadline_timer)
    finished_mono = state.clock.()

    finished = %{
      session
      | status: status,
        task: nil,
        finished_at: DateTime.utc_now(),
        finished_mono: finished_mono,
        duration_ms: max(finished_mono - session.started_mono, 0),
        results: fill_unrun(session, status)
    }

    Telemetry.session_complete(
      finished.meta,
      Atom.to_string(status),
      finished.duration_ms,
      telemetry_counts(finished)
    )

    prune(%{state | sessions: Map.put(state.sessions, session_id, finished)})
  end

  # The run body halts on its own deadline check and then returns normally, so
  # "the task finished" is not proof the run completed. A run missing results is
  # a timeout — reporting it as completed would hide the budget the run hit.
  defp resolve_status(:completed, session) do
    if map_size(session.results) == length(session.specs), do: :completed, else: :timed_out
  end

  defp resolve_status(status, _session), do: status

  # A check that never ran still gets a row, in the terminal state the run ended
  # in, so the report always has one row per catalogued check.
  defp fill_unrun(session, :completed), do: session.results
  defp fill_unrun(session, :cancelled), do: fill(session, :cancelled)
  defp fill_unrun(session, :timed_out), do: fill(session, :timed_out)
  defp fill_unrun(session, :failed), do: fill(session, :skipped)

  defp fill(session, pending_status) do
    session.specs
    |> Enum.with_index()
    |> Enum.reduce(session.results, fn {spec, index}, results ->
      Map.put_new_lazy(results, index, fn -> Descriptor.pending(spec, pending_status) end)
    end)
  end

  defp prune(state) do
    keep = retained_ids(state)
    dropped = state.order -- keep

    %{
      state
      | order: keep,
        sessions: Map.drop(state.sessions, dropped)
    }
  end

  defp retained_ids(state) do
    now = state.clock.()
    {running, finished} = Enum.split_with(state.order, &running?(state, &1))

    fresh =
      Enum.filter(finished, fn id ->
        session = Map.fetch!(state.sessions, id)
        now - session.finished_mono <= @retention_ms
      end)

    kept_finished = Enum.take(fresh, -@max_retained)
    Enum.filter(state.order, &(&1 in running or &1 in kept_finished))
  end

  defp running?(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :running}} -> true
      _other -> false
    end
  end

  defp running_count(state), do: Enum.count(state.order, &running?(state, &1))

  defp forget_ref(state, ref), do: %{state | task_refs: Map.delete(state.task_refs, ref)}

  defp fetch_view(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} -> {:ok, view(session)}
      :error -> {:error, :unknown_session}
    end
  end

  defp latest_view(state) do
    state.order
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(state.sessions, &1))
    |> Enum.find(&(&1.status in @terminal))
    |> case do
      nil -> {:error, :none}
      session -> {:ok, view(session)}
    end
  end

  defp view(session) do
    checks = ordered_results(session)

    %{
      "session_id" => session.session_id,
      "scope" => Atom.to_string(session.scope),
      "status" => Atom.to_string(session.status),
      "budget_ms" => session.budget_ms,
      "duration_ms" => session.duration_ms,
      "started_at" => DateTime.to_iso8601(session.started_at),
      "finished_at" => session.finished_at && DateTime.to_iso8601(session.finished_at),
      "total" => length(session.specs),
      "completed_count" => map_size(session.results),
      "summary" => tally(session),
      "checks" => checks
    }
  end

  defp ordered_results(session) do
    session.results
    |> Enum.sort_by(fn {index, _result} -> index end)
    |> Enum.map(fn {_index, result} -> result end)
  end

  defp tally(session) do
    counts = Enum.frequencies_by(Map.values(session.results), & &1["status"])
    Map.new(Descriptor.statuses(), fn status -> {status, Map.get(counts, status, 0)} end)
  end

  # Counts only, with atom keys the trace and Opik mappers can name. No summary
  # or evidence text ever rides the run bookends.
  defp telemetry_counts(session) do
    counts = tally(session)

    %{
      checks_total: length(session.specs),
      passed: counts["passed"],
      warning: counts["warning"],
      failed: counts["failed"],
      unavailable: counts["unavailable"],
      skipped: counts["skipped"],
      cancelled: counts["cancelled"],
      timed_out: counts["timed_out"]
    }
  end

  defp mint_session_id do
    "doctor:" <> Base.url_encode64(:crypto.strong_rand_bytes(@session_id_bytes), padding: false)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
end
