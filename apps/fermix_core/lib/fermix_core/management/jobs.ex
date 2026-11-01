defmodule FermixCore.Management.Jobs do
  @moduledoc """
  The one job family behind every long management operation (M34 native setup
  §7.3).

  A sign-in, an import, a provider probe, a plugin install, a plugin check, a
  workspace discovery, a workspace binding, a capability install, a meetings
  sign-in, a computer-use grant, a browser download and an MCP server check
  all take longer than a management request may be held open, so each is a
  *job*: the starting method mints an id and returns at once, `job.get`
  reports progress, and `job.cancel` stops it. One shape covers every family,
  so a client writes one poller, one progress row and one failure sentence
  rather than one per operation.

  Every bound is explicit and monotonic:

    * one whole-run budget per kind, after which the task is terminated and the
      job finishes `timed_out`;
    * one running job per kind and name, beyond which `start/2` is `:busy`;
    * at most four running jobs in total;
    * at most sixteen retained finished jobs, and none older than ten minutes;
    * five seconds for a stopped run to answer `:shutdown` before it is killed.

  A run that is stopped (cancelled, past its budget, or never minting the value
  its start waits for) stays `running` until its task is gone, and only then
  finishes with the outcome its stop decided: a job is never reported gone
  while its run lives, so the busy rule above holds until it is, and
  `cancel/2` answers once the run has stopped (within the grace and the kill),
  so a step started after it never runs beside the run it cancelled.

  `phase` is a closed per-kind vocabulary, published here and in the export. It
  is display copy the client turns into a sentence, never a state a client
  switches on — `status` is the state. A run that reports a phase outside its
  kind's vocabulary is a defect and fails the job loudly rather than putting a
  token on a surface that has no words for it.
  """

  use GenServer

  alias FermixCore.Management.Telemetry

  require Logger

  # Ordered, and the single source for the published vocabulary: the kinds, the
  # per-kind budget, and the phases a run of that kind may report.
  @kinds [
    provider_probe: %{budget_ms: 15_000, phases: ["calling"]},
    # M74 E5: an MCP server's sign-in finds its authorization server and its
    # client before the browser opens.
    auth: %{
      budget_ms: 300_000,
      phases: ["binding", "discovering", "registering", "awaiting_browser", "verifying"]
    },
    auth_import: %{budget_ms: 60_000, phases: ["reading_keychain", "verifying"]},
    plugin_install: %{budget_ms: 600_000, phases: ["downloading"]},
    plugin_check: %{budget_ms: 30_000, phases: ["probing"]},
    plugin_workspaces_discover: %{budget_ms: 60_000, phases: ["listing"]},
    plugin_workspace_select: %{budget_ms: 60_000, phases: ["binding"]},
    capability_install: %{
      budget_ms: 900_000,
      phases: ["sidecar_downloading", "downloading", "verifying"]
    },
    meetings_signin: %{budget_ms: 660_000, phases: ["awaiting_signin"]},
    computer_use_grant: %{budget_ms: 120_000, phases: []},
    browser_install: %{budget_ms: 900_000, phases: ["sidecar_downloading", "downloading"]},
    # M54 §12: a person answers the Automation prompt, and reads the helper's
    # own recipient dialog, so both budgets are a person's, not a machine's.
    imessage_grant: %{budget_ms: 120_000, phases: []},
    imessage_policy_confirm: %{budget_ms: 180_000, phases: []},
    # M74 §5: connecting a server the owner added, then one tool listing. A
    # first `npx -y` or `uvx` start downloads its package, and `MCP.Server`
    # gives that 60 s, so the connecting wait outlasts it.
    mcp_check: %{budget_ms: 75_000, phases: ["connecting", "listing"]},
    # M75 lean v1 §4.3: creating, powering or deleting the Always On server on
    # its provider. Each action is polled every 2 s at most 150 times, and a create
    # waits on two (the create and the start), so 15 minutes holds the worst.
    home_provision: %{
      budget_ms: 900_000,
      phases: ["checking", "firewall", "server", "starting", "power", "deleting"]
    }
  ]
  @kind_names Keyword.keys(@kinds)
  # The closed failure vocabulary a run may answer with. `timed_out` and
  # `internal_error` are minted here; the other two come from the operation.
  @operation_failures [:unavailable, :refused]
  @failure_codes ~w(unavailable refused timed_out internal_error)
  @max_concurrent 4
  @max_retained 16
  @retention_ms 600_000
  @job_id_bytes 6
  @await_timeout_ms 15_000
  # Stopping a run is cooperative first: the run is signalled `:shutdown` so a
  # body holding a resource (the cross-VM plugin store lock, a temporary tree)
  # can release it, and is killed only if it is still alive when this expires.
  # One OTP child-shutdown window, which is what the supervisor applied before.
  # Overridable at `start_link` alongside the clock, so the kill leg of the
  # bound is provable in milliseconds rather than by waiting one out.
  @cancel_grace_ms 5_000
  # A stop is answered once its run is gone, so a caller waits out the grace
  # and the kill: this much past the grace bounds its call.
  @stop_answer_margin_ms 5_000
  @timed_out_sentence "The operation did not finish inside its time budget."
  @internal_sentence "The operation failed inside the daemon."

  @type kind ::
          :provider_probe
          | :auth
          | :auth_import
          | :plugin_install
          | :plugin_check
          | :plugin_workspaces_discover
          | :plugin_workspace_select
          | :capability_install
          | :meetings_signin
          | :computer_use_grant
          | :browser_install
          | :imessage_grant
          | :imessage_policy_confirm
          | :mcp_check
          | :home_provision
  @type view :: %{String.t() => term()}
  @type report :: ({:phase, String.t()} | {:progress, map()} | {:ready, map()} -> any())
  @type outcome :: {:ok, map()} | {:error, {:unavailable | :refused, String.t()}}
  @type run :: (String.t(), report() -> outcome())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Every job kind this daemon can mint, ordered."
  @spec kinds() :: [kind()]
  def kinds, do: @kind_names

  @doc "The whole-run budget for a kind."
  @spec budget_ms(kind()) :: pos_integer()
  def budget_ms(kind) when kind in @kind_names, do: descriptor(kind).budget_ms

  @doc "The closed phase vocabulary a run of this kind may report."
  @spec phases(kind()) :: [String.t()]
  def phases(kind) when kind in @kind_names, do: descriptor(kind).phases

  @doc "Every failure code a job may carry, ordered."
  @spec failure_codes() :: [String.t()]
  def failure_codes, do: @failure_codes

  @spec max_concurrent() :: pos_integer()
  def max_concurrent, do: @max_concurrent

  @spec max_retained() :: pos_integer()
  def max_retained, do: @max_retained

  @spec retention_ms() :: pos_integer()
  def retention_ms, do: @retention_ms

  @doc """
  Starts one bounded run.

  `:name` is the single-flight name inside the kind, `:run` the body — an
  arity-2 function handed the job id and a reporter, answering `{:ok,
  flat_result}` or `{:error, {code, sentence}}`. The job id is the run's
  `session_id`, so a provider call made inside the run nests under it. `:await`
  holds the reply until the run reports `{:ready, extra}`, which is how
  `auth.start` hands back an authorize url the run mints and no later read
  repeats.
  """
  @spec start(kind(), keyword()) :: {:ok, view()} | {:error, :busy | :await_timeout}
  def start(kind, opts) when kind in @kind_names and is_list(opts) do
    GenServer.call(server(opts), {:start, kind, opts}, start_timeout(opts))
  end

  @spec get(String.t(), keyword()) :: {:ok, view()} | {:error, :unknown_job}
  def get(job_id, opts \\ []) when is_binary(job_id) and is_list(opts) do
    GenServer.call(server(opts), {:get, job_id})
  end

  @spec list(keyword()) :: {:ok, [view()]}
  def list(opts \\ []) when is_list(opts), do: GenServer.call(server(opts), :list)

  @doc """
  Stops a running job and answers its terminal view once its run has
  stopped; a finished job answers as it is.
  """
  @spec cancel(String.t(), keyword()) :: {:ok, view()} | {:error, :unknown_job}
  def cancel(job_id, opts \\ []) when is_binary(job_id) and is_list(opts) do
    GenServer.call(server(opts), {:cancel, job_id}, @cancel_grace_ms + @stop_answer_margin_ms)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       jobs: %{},
       order: [],
       task_refs: %{},
       shutting_down: %{},
       task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
       cancel_grace_ms: Keyword.get(opts, :cancel_grace_ms, @cancel_grace_ms),
       clock: Keyword.get(opts, :clock, &monotonic_ms/0)
     }}
  end

  @impl true
  def handle_call({:start, kind, opts}, from, state) do
    name = Keyword.fetch!(opts, :name)

    cond do
      running?(state, kind, name) -> {:reply, {:error, :busy}, state}
      running_count(state) >= @max_concurrent -> {:reply, {:error, :busy}, state}
      true -> start_job(state, kind, name, opts, from)
    end
  end

  # Retention is a promise about age, so it is applied on the read as well as on
  # the write: a daemon that starts no further job would otherwise keep
  # answering with a job it says it has already dropped.
  def handle_call({:get, job_id}, _from, state) do
    state = prune(state)
    {:reply, fetch_view(state, job_id), state}
  end

  def handle_call(:list, _from, state) do
    state = prune(state)
    {:reply, {:ok, Enum.map(state.order, &view(Map.fetch!(state.jobs, &1)))}, state}
  end

  def handle_call({:cancel, job_id}, from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, %{status: :running}} -> {:noreply, cancel_job(state, job_id, from)}
      {:ok, job} -> {:reply, {:ok, view(job)}, state}
      :error -> {:reply, {:error, :unknown_job}, state}
    end
  end

  @impl true
  def handle_info({:job_event, job_id, event}, state) do
    {:noreply, apply_event(state, job_id, event)}
  end

  def handle_info({:deadline, job_id}, state) do
    {:noreply, stop_job(state, job_id, timed_out())}
  end

  def handle_info({:await_timeout, job_id}, state) do
    {:noreply, await_timeout(state, job_id)}
  end

  def handle_info({:kill_task, ref}, state) when is_reference(ref) do
    {:noreply, kill_task(state, ref)}
  end

  def handle_info({ref, outcome}, state) when is_reference(ref) do
    {:noreply, complete_task(state, ref, outcome)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    {:noreply, task_down(state, ref, reason)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_job(state, kind, name, opts, from) do
    job_id = mint_job_id()
    budget_ms = Keyword.get(opts, :budget_ms, budget_ms(kind))
    task = spawn_run(state, job_id, Keyword.fetch!(opts, :run))

    job = %{
      job_id: job_id,
      kind: kind,
      name: name,
      status: :running,
      phase: nil,
      progress: nil,
      budget_ms: budget_ms,
      started_at: DateTime.utc_now(),
      started_mono: state.clock.(),
      finished_at: nil,
      finished_mono: nil,
      result: nil,
      failure: nil,
      extra: %{},
      stopping: nil,
      waiters: [],
      task: task,
      deadline_timer: Process.send_after(self(), {:deadline, job_id}, budget_ms),
      awaiting: awaiting(opts, job_id, from)
    }

    Telemetry.job_start(meta(job))
    state = state |> put_job(job) |> track_ref(task.ref, job_id) |> prune()

    if job.awaiting, do: {:noreply, state}, else: {:reply, {:ok, view(job)}, state}
  end

  defp spawn_run(state, job_id, run) when is_function(run, 2) do
    owner = self()
    reporter = fn event -> send(owner, {:job_event, job_id, event}) end

    Task.Supervisor.async_nolink(state.task_supervisor, fn -> run.(job_id, reporter) end)
  end

  defp awaiting(opts, job_id, from) do
    if Keyword.get(opts, :await, false) do
      timeout = Keyword.get(opts, :await_timeout_ms, @await_timeout_ms)

      %{
        from: from,
        timer: Process.send_after(self(), {:await_timeout, job_id}, timeout),
        answer: :view
      }
    end
  end

  # The caller is answered when the run has stopped (`close/3`), however many
  # ask; the first stop's outcome is the one the job ends with.
  defp cancel_job(state, job_id, from) do
    state = stop_job(state, job_id, cancelled())
    job = Map.fetch!(state.jobs, job_id)
    put_job(state, %{job | waiters: [from | job.waiters]})
  end

  # A run being stopped reports nothing more: its outcome is already decided.
  defp apply_event(state, job_id, event) do
    case running_job(state, job_id) do
      {:ok, %{stopping: nil} = job} -> apply_running_event(state, job, event)
      _stopping_finished_or_unknown -> state
    end
  end

  # A phase outside the kind's published vocabulary is a daemon defect, not an
  # operator-visible refusal: the client has no sentence for it and would draw
  # nothing, so the run stops here and says why.
  defp apply_running_event(state, job, {:phase, phase}) when is_binary(phase) do
    if phase in phases(job.kind) do
      put_job(state, %{job | phase: phase})
    else
      Logger.error("management job #{job.job_id} reported unpublished phase #{inspect(phase)}")
      stop_job(state, job.job_id, internal_failure())
    end
  end

  defp apply_running_event(state, job, {:progress, %{done: done, total: total, unit: unit}})
       when is_integer(done) and done >= 0 do
    put_job(state, %{job | progress: %{"done" => done, "total" => total, "unit" => unit}})
  end

  defp apply_running_event(state, job, {:ready, extra}) when is_map(extra) do
    state |> put_job(%{job | extra: extra}) |> release_await(job.job_id)
  end

  defp apply_running_event(state, job, event) do
    Logger.error("management job #{job.job_id} reported an invalid event #{inspect(event)}")
    stop_job(state, job.job_id, internal_failure())
  end

  defp release_await(state, job_id) do
    job = Map.fetch!(state.jobs, job_id)

    case job.awaiting do
      %{from: from, timer: timer, answer: :view} ->
        _ = Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, Map.merge(view(job), job.extra)})
        put_job(state, %{job | awaiting: nil})

      _none_or_refused ->
        state
    end
  end

  # The run never minted the value the caller is waiting for. The run stops,
  # and the caller is refused once it has: leaving it going would hold a
  # loopback port open for a flow nothing is watching.
  defp await_timeout(state, job_id) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, %{awaiting: %{answer: :view} = awaiting} = job} ->
        refused = %{awaiting | timer: nil, answer: :await_timeout}

        state
        |> put_job(%{job | awaiting: refused})
        |> stop_job(job_id, cancelled())

      _absent_released_or_refused ->
        state
    end
  end

  defp stop_job(state, job_id, outcome) do
    case running_job(state, job_id) do
      {:ok, %{stopping: nil} = job} -> terminate(state, job, outcome)
      _stopping_finished_or_unknown -> state
    end
  end

  # The run is asked to stop rather than killed outright, so a body holding a
  # resource can release it; the monitor stays up, and its `:DOWN` closes the
  # job with `outcome` (`stopped/2`). Until then the job is still running.
  defp terminate(state, job, outcome) do
    Process.exit(job.task.pid, :shutdown)

    state
    |> forget_ref(job.task.ref)
    |> arm_kill(job.task, job.job_id)
    |> put_job(%{job | stopping: outcome})
  end

  # Bounded by construction: one entry per running job, at most `@max_concurrent`
  # of them, each cleared by the `:DOWN` its monitor guarantees.
  defp arm_kill(state, task, job_id) do
    timer = Process.send_after(self(), {:kill_task, task.ref}, state.cancel_grace_ms)
    entry = %{pid: task.pid, timer: timer, job_id: job_id}
    %{state | shutting_down: Map.put(state.shutting_down, task.ref, entry)}
  end

  # The grace expired with the run still alive: it is killed unconditionally,
  # and the `:DOWN` that follows clears the entry.
  defp kill_task(state, ref) do
    case Map.fetch(state.shutting_down, ref) do
      {:ok, %{pid: pid}} ->
        Logger.error("management run #{inspect(pid)} ignored :shutdown and was killed")
        Process.exit(pid, :kill)
        state

      :error ->
        state
    end
  end

  # A stopped run is gone, inside its grace or by the kill: the kill is
  # disarmed and its job closes with the outcome its stop decided.
  defp stopped(state, ref) do
    case Map.pop(state.shutting_down, ref) do
      {nil, _shutting_down} ->
        state

      {%{timer: timer, job_id: job_id}, remaining} ->
        _ = Process.cancel_timer(timer)
        state = %{state | shutting_down: remaining}
        finish(state, job_id, Map.fetch!(state.jobs, job_id).stopping)
    end
  end

  defp complete_task(state, ref, outcome) do
    case Map.fetch(state.task_refs, ref) do
      {:ok, job_id} ->
        Process.demonitor(ref, [:flush])
        state |> forget_ref(ref) |> finish(job_id, classify(job_id, outcome))

      :error ->
        state
    end
  end

  defp task_down(state, ref, reason) do
    case Map.fetch(state.task_refs, ref) do
      {:ok, job_id} ->
        Logger.error("management job #{job_id} crashed: #{inspect(reason)}")
        state |> forget_ref(ref) |> finish(job_id, internal_failure())

      :error ->
        stopped(state, ref)
    end
  end

  defp classify(_job_id, {:ok, result}) when is_map(result) do
    if flat_scalars?(result) do
      %{status: :completed, result: result, failure: nil}
    else
      %{status: :failed, result: nil, failure: failure("internal_error", @internal_sentence)}
    end
  end

  defp classify(_job_id, {:error, {code, sentence}})
       when code in @operation_failures and is_binary(sentence) do
    %{status: :failed, result: nil, failure: failure(Atom.to_string(code), sentence)}
  end

  defp classify(job_id, outcome) do
    Logger.error("management job #{job_id} answered an invalid outcome #{inspect(outcome)}")
    internal_failure()
  end

  defp finish(state, job_id, outcome) do
    case running_job(state, job_id) do
      {:ok, job} -> close(state, job, outcome)
      :error -> state
    end
  end

  defp close(state, job, outcome) do
    _ = Process.cancel_timer(job.deadline_timer)
    finished_mono = state.clock.()

    finished = %{
      job
      | status: outcome.status,
        phase: retained_phase(job.phase, outcome.status),
        result: outcome.result,
        failure: outcome.failure,
        stopping: nil,
        waiters: [],
        task: nil,
        finished_at: DateTime.utc_now(),
        finished_mono: finished_mono
    }

    Telemetry.job_complete(
      meta(finished),
      Atom.to_string(outcome.status),
      max(finished_mono - job.started_mono, 0),
      outcome.failure
    )

    Enum.each(job.waiters, &GenServer.reply(&1, {:ok, view(finished)}))
    state |> put_job(finished) |> release_terminal_await(finished.job_id) |> prune()
  end

  # A caller still waiting on a value the run was going to mint gets the job it
  # asked for, in the state it ended in, rather than a bare refusal that says
  # nothing about why the flow stopped; one whose wait ran out is refused, now
  # that the run it waited on has stopped.
  defp release_terminal_await(state, job_id) do
    job = Map.fetch!(state.jobs, job_id)

    case job.awaiting do
      nil ->
        state

      %{from: from, timer: timer, answer: answer} ->
        _ = timer && Process.cancel_timer(timer)
        GenServer.reply(from, terminal_answer(answer, job))
        put_job(state, %{job | awaiting: nil})
    end
  end

  defp terminal_answer(:view, job), do: {:ok, view(job)}
  defp terminal_answer(:await_timeout, _job), do: {:error, :await_timeout}

  # The phase a run died in is part of the diagnosis; a clean finish has no
  # current step and says so rather than leaving the last one standing.
  defp retained_phase(phase, status) when status in [:failed, :timed_out], do: phase
  defp retained_phase(_phase, _status), do: nil

  defp prune(state) do
    keep = retained_ids(state)
    dropped = state.order -- keep

    %{state | order: keep, jobs: Map.drop(state.jobs, dropped)}
  end

  defp retained_ids(state) do
    now = state.clock.()
    {running, finished} = Enum.split_with(state.order, &running?(state, &1))

    fresh =
      Enum.filter(finished, fn id ->
        now - Map.fetch!(state.jobs, id).finished_mono <= @retention_ms
      end)

    kept = Enum.take(fresh, -@max_retained)
    Enum.filter(state.order, &(&1 in running or &1 in kept))
  end

  defp put_job(state, job), do: %{state | jobs: Map.put(state.jobs, job.job_id, job)}

  defp track_ref(state, ref, job_id) do
    %{state | order: state.order ++ [job_id], task_refs: Map.put(state.task_refs, ref, job_id)}
  end

  defp forget_ref(state, ref), do: %{state | task_refs: Map.delete(state.task_refs, ref)}

  defp running_job(state, job_id) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, %{status: :running} = job} -> {:ok, job}
      _finished_or_unknown -> :error
    end
  end

  defp running?(state, job_id) when is_binary(job_id), do: running_job(state, job_id) != :error

  defp running?(state, kind, name) do
    Enum.any?(state.order, fn id ->
      job = Map.fetch!(state.jobs, id)
      job.status == :running and job.kind == kind and job.name == name
    end)
  end

  defp running_count(state), do: Enum.count(state.order, &running?(state, &1))

  defp fetch_view(state, job_id) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} -> {:ok, view(job)}
      :error -> {:error, :unknown_job}
    end
  end

  defp view(job) do
    %{
      "job_id" => job.job_id,
      "kind" => Atom.to_string(job.kind),
      "status" => Atom.to_string(job.status),
      "phase" => job.phase,
      "progress" => job.progress,
      "budget_ms" => job.budget_ms,
      "started_at" => DateTime.to_iso8601(job.started_at),
      "finished_at" => job.finished_at && DateTime.to_iso8601(job.finished_at),
      "result" => job.result,
      "failure" => job.failure
    }
  end

  defp meta(job), do: %{job_id: job.job_id, kind: job.kind, budget_ms: job.budget_ms}

  defp cancelled, do: %{status: :cancelled, result: nil, failure: nil}

  defp timed_out do
    %{status: :timed_out, result: nil, failure: failure("timed_out", @timed_out_sentence)}
  end

  defp internal_failure do
    %{status: :failed, result: nil, failure: failure("internal_error", @internal_sentence)}
  end

  defp failure(code, sentence), do: %{"code" => code, "sentence" => sentence}

  defp flat_scalars?(result) do
    Enum.all?(result, fn {key, value} -> is_binary(key) and scalar?(value) end)
  end

  defp scalar?(value) when is_binary(value) or is_number(value) or is_boolean(value), do: true
  defp scalar?(nil), do: true
  defp scalar?(_value), do: false

  defp mint_job_id do
    "job:" <> Base.url_encode64(:crypto.strong_rand_bytes(@job_id_bytes), padding: false)
  end

  # A job whose reply is deferred until the run mints a value still answers
  # inside the await bound, or once the run that never minted it has stopped,
  # so the call's own timeout tracks both rather than the GenServer default.
  defp start_timeout(opts) do
    Keyword.get(opts, :await_timeout_ms, @await_timeout_ms) + @cancel_grace_ms +
      @stop_answer_margin_ms
  end

  defp descriptor(kind), do: Keyword.fetch!(@kinds, kind)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
end
