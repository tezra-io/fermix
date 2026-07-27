defmodule FermixCore.Harness.Manager do
  @moduledoc """
  Permanent GenServer that owns the local coding-harness run lifecycle
  (design §6.4, §9.2, §12.3).

  It is the single admission, terminalization, and reconciliation authority —
  the Jobs.Scheduler precedent, mirrored: stable process monitors temporary
  `Harness.Run` workers under `Harness.RunSupervisor` and terminalizes an
  abnormal DOWN. Responsibilities:

    * **Admission (`start_run/2`).** All lifecycle state is persisted before any
      OS spawn: build the adapter plan, resolve the canonical git worktree lock
      root, check the artifact quota, then `Ledger.admit` the row `starting`
      (holding its workspace locks and a capacity slot) — and only then start the
      run under the supervisor, monitor it, and emit the single `run_start`
      event. Param/validation errors return `{:error, _}` with no row; the
      environmental blocks (`cli_unavailable`, `artifact_quota`) are ledgered as
      `blocked` + delivered only for a scheduled origin (the owner must hear),
      while an attended chat gets the refusal inline (design §12.1 / spec D8).
    * **Terminalization (`report_terminal`).** `Harness.Run` never writes the
      terminal ledger row — it reports to this process, which is the single
      terminal writer: `Ledger.terminalize` (the P0 `:already_terminal` guard is
      the idempotence backstop), then `run_complete`/`run_error` telemetry, the
      untrusted-provenance memory write-back (completed only), and the outcome
      hand-off: a chat-origin run inside the chain cap re-enters its conversation
      through `Harness.Continuation` (§23.2), everything else takes one inline
      delivery attempt (`DeliveryWorker` owns every subsequent attempt).
    * **Monitoring.** An abnormal `Harness.Run` DOWN with a still-active row →
      `failed/:run_crashed` + delivery, exactly mirroring the scheduler's monitor
      map + `:normal`/`:shutdown` drop-only handling.
    * **Boot reconciliation (`handle_continue`).** Non-terminal local rows are
      finalized `interrupted` with resume guidance in the delivery, then a bounded
      artifact GC runs and the daily GC timer is armed. Never blocks the
      supervisor. Cloud (`submitting`/`polling`) rows are P2 — logged, not
      touched.

  GenServer callbacks stay thin; every branch delegates to a private function.
  """

  use GenServer

  require Logger

  alias FermixCore.CommandHost.Supervisor, as: CommandHostSupervisor
  alias FermixCore.CommandRunner
  alias FermixCore.Harness.Adapters.CodexCloud
  alias FermixCore.Harness.Artifacts
  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Consent
  alias FermixCore.Harness.Continuation
  alias FermixCore.Harness.Delivery
  alias FermixCore.Harness.Env
  alias FermixCore.Harness.Ledger
  alias FermixCore.Harness.MemoryWriteback
  alias FermixCore.Harness.Run
  alias FermixCore.Harness.RunSupervisor
  alias FermixCore.Harness.Telemetry
  alias FermixCore.Harness.Vendors
  alias FermixCore.Harness.Workspace
  alias FermixCore.Memory.Repo

  @start_call_timeout_ms 60_000
  @default_gc_interval_ms 86_400_000

  # Cloud submit/status commands are short supervised buffered runs (§5.3); their
  # wall-clock is bounded well under the GenServer call timeout so a hung vendor
  # command can never wedge the manager past the deadline.
  @cloud_submit_timeout_ms 45_000
  @cloud_status_timeout_ms 30_000
  @cloud_prompt_file "prompt.md"

  @type run_id :: String.t()
  @type request :: %{
          required(:vendor) => String.t(),
          required(:adapter) => module(),
          required(:prompt) => String.t(),
          required(:cwd) => String.t(),
          required(:ctx) => map(),
          required(:snapshot) => map(),
          required(:origin_session_id) => String.t(),
          optional(:params) => map(),
          optional(:timeout_minutes) => pos_integer(),
          optional(:progress) => atom() | String.t(),
          optional(:continuation_depth) => non_neg_integer()
        }

  # --- Public API ---------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Admits and starts a local run, returning its id. Refusals: `:max_active`
  (capacity), `{:workspace_locked, root}` (contention), `:cli_unavailable`
  (missing binary), `{:artifact_quota, detail}`, or a plan/param error term.
  """
  @spec start_run(request(), GenServer.server()) :: {:ok, run_id()} | {:error, term()}
  def start_run(request, server \\ __MODULE__) when is_map(request) do
    GenServer.call(server, {:start_run, normalize_request(request)}, @start_call_timeout_ms)
  end

  @doc """
  Admits and submits a Codex cloud run, returning its id once the row is written
  (whether it is now `polling` or already terminalized `blocked` by a submit
  failure). The submit CLI runs inline in this call (a short supervised buffered
  command), so a param error (`:unknown_param`/`:invalid_param`/`:query_too_large`)
  returns `{:error, _}` with NO row; a missing binary is the D8 environmental
  block. `request` carries `%{params, snapshot, origin_session_id, ctx,
  continuation_depth}` where `params` is the adapter's `%{query, env_id, branch?,
  attempts?}`.
  """
  @spec start_cloud_run(map(), GenServer.server()) :: {:ok, run_id()} | {:error, term()}
  def start_cloud_run(request, server \\ __MODULE__) when is_map(request) do
    GenServer.call(
      server,
      {:start_cloud_run, normalize_cloud_request(request)},
      @start_call_timeout_ms
    )
  end

  @doc """
  Abandons tracking of an active cloud run: cancels its poll timer, terminalizes
  it `blocked/:tracking_stopped`, and delivers the task URL — never claiming the
  vendor task itself stopped (no cancel exists on that surface). Returns
  `{:ok, task_url}`. A local run is `{:error, :not_cloud}`; an already-terminal
  cloud run is `{:error, :already_terminal}`; an unknown id is `{:error, :not_found}`.
  """
  @spec stop_tracking(run_id(), GenServer.server()) ::
          {:ok, String.t() | nil} | {:error, :not_found | :not_cloud | :already_terminal}
  def stop_tracking(run_id, server \\ __MODULE__) when is_binary(run_id) do
    GenServer.call(server, {:stop_tracking, run_id})
  end

  @doc """
  Requests owner cancellation of an active run (terminalizes `cancelled`). A run
  that is already terminal is `{:error, :already_terminal}`; an unknown id is
  `{:error, :not_found}`.
  """
  @spec cancel(run_id(), :owner, GenServer.server()) ::
          :ok | {:error, :not_found | :already_terminal}
  def cancel(run_id, :owner, server \\ __MODULE__) when is_binary(run_id) do
    GenServer.call(server, {:cancel, run_id, :owner})
  end

  @doc """
  Cancels every active run (owner intent) and returns the count. The `/stop`
  third participant (spec C2 / D9) — global, not per-conversation.
  """
  @spec stop_all(GenServer.server()) :: %{cancelled: non_neg_integer()}
  def stop_all(server \\ __MODULE__) do
    GenServer.call(server, :stop_all)
  end

  @doc """
  Ledgers a `blocked/<reason>` outcome (with delivery) for a scheduled-origin
  LOCAL run refused before admission — a `cwd` the sandbox denied
  (`:workspace_denied`) or an unapproved coding-agent launch (`:consent_required`,
  design §22). The tool layer checks these, and for a cron origin the owner must
  hear (design §12.1, spec D8); attended chat gets the refusal inline and never
  calls this. `block` carries `%{vendor, cwd, snapshot, origin_session_id,
  reason}`; always replies `:ok`.
  """
  @spec block_scheduled(map(), GenServer.server()) :: :ok
  def block_scheduled(block, server \\ __MODULE__) when is_map(block) do
    GenServer.call(server, {:block_scheduled, block})
  end

  @doc """
  Ledgers a `blocked/<reason>` outcome (with delivery) for a scheduled-origin
  CLOUD run refused before submission — the cloud analogue of `block_scheduled/2`
  (used by the first-use consent gate, `:consent_required`). `block` carries
  `%{params: %{env_id: ...}, snapshot, origin_session_id, reason}`; always
  replies `:ok`.
  """
  @spec block_scheduled_cloud(map(), GenServer.server()) :: :ok
  def block_scheduled_cloud(block, server \\ __MODULE__) when is_map(block) do
    GenServer.call(server, {:block_scheduled_cloud, block})
  end

  # --- GenServer ----------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, build_state(opts), {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, %{timer_enabled?: false} = state), do: {:noreply, state}

  def handle_continue(:reconcile, state) do
    {:noreply, state |> reconcile() |> run_gc() |> arm_gc_timer()}
  end

  @impl true
  def handle_call({:start_run, request}, _from, state) do
    {reply, state} = admit_and_start(request, state)
    {:reply, reply, state}
  end

  def handle_call({:start_cloud_run, request}, _from, state) do
    {reply, state} = admit_cloud(request, state)
    {:reply, reply, state}
  end

  def handle_call({:stop_tracking, run_id}, _from, state) do
    stop_tracking_call(run_id, state)
  end

  def handle_call({:cancel, run_id, :owner}, _from, state) do
    case Map.get(state.runs, run_id) do
      nil ->
        {:reply, terminal_cancel_reply(run_id, state), state}

      %{cloud: true} = info ->
        {:reply, {:error, {:vendor_cancel_unsupported, info.task_url}}, state}

      run_info ->
        {:reply, request_cancel(run_info), state}
    end
  end

  # /stop is global but only kills local process groups — a cloud task has no
  # cancel surface, so `stop_all` skips cloud rows and the reply counts local runs
  # only (D18). Cloud polling continues; the owner uses `stop_tracking` to abandon it.
  def handle_call(:stop_all, _from, state) do
    local = Enum.filter(state.runs, fn {_id, info} -> local_info?(info) end)
    Enum.each(local, fn {_id, info} -> Run.cancel(info.pid, :owner) end)
    {:reply, %{cancelled: length(local)}, state}
  end

  def handle_call({:block_scheduled, block}, _from, state) do
    {:reply, :ok, ledger_block(block, Map.fetch!(block, :reason), state)}
  end

  def handle_call({:block_scheduled_cloud, block}, _from, state) do
    {:reply, :ok, ledger_cloud_block(block, Map.fetch!(block, :reason), state)}
  end

  @impl true
  def handle_info({:harness_report_terminal, run_id, status, fields}, state) do
    {:noreply, finalize_reported(state, run_id, status, fields)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, handle_down(ref, reason, state)}
  end

  def handle_info(:harness_gc, state) do
    {:noreply, state |> run_gc() |> arm_gc_timer()}
  end

  def handle_info({:cloud_poll, run_id}, state) do
    {:noreply, poll_tick(state, run_id)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- Admission ----------------------------------------------------------

  defp admit_and_start(request, state) do
    case plan_for(request) do
      {:ok, plan} -> admit_with_plan(request, plan, state)
      {:error, :cli_unavailable} -> block_or_error(request, :cli_unavailable, state)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp plan_for(request) do
    request.adapter.plan(request.params, request.ctx)
  end

  defp admit_with_plan(request, plan, state) do
    case Workspace.lock_root(plan.cwd) do
      {:ok, worktree_root} -> admit_with_worktree(request, plan, worktree_root, state)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp admit_with_worktree(request, plan, worktree_root, state) do
    case Artifacts.admission_check(state.artifacts_opts) do
      :ok -> admit_and_spawn(request, plan, worktree_root, state)
      {:error, {:artifact_quota, _detail} = reason} -> block_or_error(request, reason, state)
    end
  end

  defp admit_and_spawn(request, plan, worktree_root, state) do
    run_id = Ledger.generate_id()
    lock_roots = Enum.uniq([worktree_root | plan.extra_lock_roots])
    attrs = admit_attrs(request, plan, run_id, worktree_root, lock_roots, "starting", state)

    case Ledger.admit(attrs, server: state.repo) do
      {:ok, row} -> launch(row, plan, request, state)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp launch(row, plan, request, state) do
    case RunSupervisor.start_run(state.run_supervisor, build_run_args(row, plan, request, state)) do
      {:ok, pid} ->
        {{:ok, row.id}, track_started(state, row, pid, request)}

      {:error, reason} ->
        Logger.error("harness run #{row.id} failed to start: #{inspect(reason)}")
        {{:error, reason}, terminalize_and_notify(state, row.id, crash_outcome(), nil)}
    end
  end

  defp track_started(state, row, pid, request) do
    ref = Process.monitor(pid)
    Telemetry.run_start(row, request.prompt, max_duration_ms(request))

    run_info = %{pid: pid, ref: ref}

    %{
      state
      | runs: Map.put(state.runs, row.id, run_info),
        run_monitors: Map.put(state.run_monitors, ref, row.id)
    }
  end

  # Environmental blocks (spec D8): a scheduled origin ledgers a `blocked` row and
  # delivers it (the owner must hear); an attended chat gets the refusal inline in
  # the tool result, so no row is written.
  defp block_or_error(%{snapshot: %{origin_kind: "scheduled"}} = request, reason, state) do
    {{:error, reason}, ledger_block(request, reason, state)}
  end

  defp block_or_error(_request, reason, state), do: {{:error, reason}, state}

  defp ledger_block(request, reason, state) do
    run_id = Ledger.generate_id()
    attrs = admit_attrs(request, nil, run_id, request.cwd, [], "starting", state)

    case Ledger.admit(attrs, server: state.repo) do
      {:ok, _row} -> terminalize_and_notify(state, run_id, block_outcome(reason), nil)
      {:error, admit_error} -> log_block_unledgered(run_id, reason, admit_error, state)
    end
  end

  defp log_block_unledgered(run_id, reason, admit_error, state) do
    Logger.warning(
      "harness block #{run_id} (#{inspect(reason)}) could not be ledgered: #{inspect(admit_error)}"
    )

    state
  end

  # `plan` is `nil` for a `cli_unavailable` block (no plan was produced); the row
  # then carries no lock roots and the request-level `cwd`/vendor.
  defp admit_attrs(request, plan, run_id, worktree_root, lock_roots, status, state) do
    snapshot = request.snapshot

    %{
      id: run_id,
      vendor: request.vendor,
      rail: "local",
      status: status,
      cwd: plan_cwd(plan, request),
      worktree_root: worktree_root,
      lock_roots: lock_roots,
      artifacts_dir: artifacts_dir_for(run_id, state.artifacts_opts),
      resumable: plan_resumable(plan),
      origin_kind: Map.fetch!(snapshot, :origin_kind),
      origin_session_id: request.origin_session_id,
      # The launching turn's chain depth (0 for an owner-typed request), so this
      # run's own completion knows whether it may continue (§23.2). A `block`
      # request carries none.
      continuation_depth: Map.get(request, :continuation_depth, 0),
      parent_job_id: Map.get(snapshot, :parent_job_id),
      delivery_mode: Map.fetch!(snapshot, :delivery_mode),
      platform: Map.get(snapshot, :platform),
      destination: Map.get(snapshot, :destination),
      thread: Map.get(snapshot, :thread),
      send_opts: Map.get(snapshot, :send_opts)
    }
  end

  defp plan_cwd(nil, request), do: request.cwd
  defp plan_cwd(plan, _request), do: plan.cwd

  defp plan_resumable(nil), do: true
  defp plan_resumable(plan), do: plan.resumable

  defp artifacts_dir_for(run_id, artifacts_opts) do
    Path.join(Artifacts.runs_root(artifacts_opts), run_id)
  end

  defp build_run_args(row, plan, request, state) do
    %{
      row: row,
      plan: plan,
      prompt: request.prompt,
      adapter: request.adapter,
      manager: self(),
      repo: state.repo,
      runs_root: Keyword.get(state.artifacts_opts, :runs_root),
      command_supervisor: state.command_supervisor,
      timeout_minutes: request.timeout_minutes,
      progress: request.progress,
      notice_fn: build_notice_fn(row, state),
      # The daemon-environment opts reach BOTH rails: the cloud path already read
      # them off the state, and forwarding them here means one manager option means
      # one thing everywhere. All three are nil in production — Run resolves them
      # from the daemon env exactly as before — so this exists to give the local
      # rail the same test seam the cloud rail has. Without it a local-run test can
      # only inherit the host's identity, and USER is now a hard requirement.
      home: state.home,
      path: state.path,
      user: state.user
    }
  end

  defp build_notice_fn(row, state) do
    delivery_opts = state.delivery_opts
    fn text -> Delivery.notice(row, text, delivery_opts) end
  end

  defp max_duration_ms(request) do
    (request.timeout_minutes || Config.default_timeout_minutes()) * 60_000
  end

  defp local_info?(info), do: not Map.get(info, :cloud, false)

  # --- Cloud admission + submit -------------------------------------------

  # Same admission discipline as local: validate the submit argv first (param
  # errors return `{:error, _}` with no row, like a local plan error); a missing
  # binary is the D8 environmental block. Only then insert the `submitting` row and
  # run the submit CLI inline.
  defp admit_cloud(request, state) do
    case CodexCloud.submit_argv(request.params, cloud_submit_opts(request, state)) do
      {:ok, submit} -> admit_cloud_row(request, submit, state)
      {:error, :cli_unavailable} -> block_or_error_cloud(request, :cli_unavailable, state)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp admit_cloud_row(request, submit, state) do
    run_id = Ledger.generate_id()

    case Ledger.admit(cloud_admit_attrs(request, run_id, "submitting", state), server: state.repo) do
      {:ok, row} -> prepare_and_submit(row, submit, request, state)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  # Persist lifecycle before work: prepare the artifacts dir, snapshot the query
  # (so a crash-mid-submit reconciliation can recover it), open the run trace, then
  # run the submit. The prompt snapshot is best-effort — its failure never blocks
  # the submit (the reconciliation delivery simply notes the query is unavailable).
  defp prepare_and_submit(row, submit, request, state) do
    case Artifacts.prepare(row.id, state.artifacts_opts) do
      {:ok, %{dir: dir}} ->
        submit_prepared(row, dir, submit, request, state)

      {:error, reason} ->
        cloud_terminal_at_admit(
          row,
          submit_failed_outcome("artifact_prepare:#{inspect(reason)}"),
          state
        )
    end
  end

  defp submit_prepared(row, dir, submit, request, state) do
    _ = Artifacts.snapshot_prompt(dir, cloud_query(request))
    Telemetry.run_start(row, cloud_query(request), state.cloud_poll_max_ms)
    run_submit(row, submit, request, state)
  end

  defp run_submit(row, submit, request, state) do
    case cloud_command(submit.binary, submit.argv, cloud_artifacts_dir(row, state), state) do
      {:ok, %{exit: code, stdout: out}} ->
        classify_submit(row, out, code, request, state)

      {:error, {:timeout, _ms}} ->
        cloud_terminal_at_admit(row, submit_failed_outcome("submit timed out"), state)

      {:error, reason} ->
        cloud_terminal_at_admit(row, submit_failed_outcome("submit:#{inspect(reason)}"), state)
    end
  end

  defp classify_submit(row, out, code, request, state) do
    case CodexCloud.parse_submit(out, code) do
      {:ok, %{task_id: task_id, task_url: task_url}} ->
        begin_polling(row, task_id, task_url, request, state)

      {:error, :cloud_auth} ->
        cloud_terminal_at_admit(row, cloud_auth_outcome(), state)

      {:error, {:command_failed, detail}} ->
        cloud_terminal_at_admit(row, submit_failed_outcome(detail), state)

      {:error, {:submit_parse, detail}} ->
        cloud_terminal_at_admit(row, submit_failed_outcome(detail), state)
    end
  end

  # A synchronous submit-time terminalization: the row exists (`submitting`), so it
  # is finalized here — the outcome reaches the owner through the same completion
  # path as any other terminal (continuation for a chat origin, delivery
  # otherwise), and the tool still receives `{:ok, run_id}`.
  defp cloud_terminal_at_admit(row, outcome, state) do
    {{:ok, row.id}, terminalize_and_notify(state, row.id, outcome, nil)}
  end

  defp begin_polling(row, task_id, task_url, request, state) do
    now = state.now_fn.()
    next = DateTime.add(now, state.cloud_poll_ms, :millisecond)
    deadline = DateTime.add(now, state.cloud_poll_max_ms, :millisecond)

    fields = %{task_id: task_id, task_url: task_url, next_poll_at: next, poll_deadline: deadline}

    case Ledger.mark_polling(row.id, fields, server: state.repo) do
      {:ok, _row} ->
        {{:ok, row.id}, arm_polling(state, row, request, task_id, task_url, deadline)}

      # The submit SUCCEEDED — a live vendor task exists (`task_id`/`task_url` in
      # hand) — but its poll schedule could not be persisted, so tracking cannot
      # continue. Not `submit_failed` (submit did not fail): terminalize the
      # tracking-lost outcome carrying the task URL so the delivery still points at
      # the live task, and never auto-resubmit (§5.3).
      {:error, reason} ->
        cloud_terminal_at_admit(
          row,
          tracking_lost_outcome(task_id, task_url, "mark_polling:#{inspect(reason)}"),
          state
        )
    end
  end

  defp arm_polling(state, row, request, task_id, task_url, deadline) do
    info =
      cloud_info(row, state, %{
        task_id: task_id,
        task_url: task_url,
        poll_deadline: deadline,
        find_executable: cloud_find_executable(request.ctx, state)
      })

    put_and_arm(state, row.id, info, state.cloud_poll_ms)
  end

  # Environmental block on a cloud submit (missing binary): ledger + deliver for a
  # scheduled origin (the owner must hear), inline-only refusal for attended chat
  # (D8) — the local `block_or_error` mirror.
  defp block_or_error_cloud(%{snapshot: %{origin_kind: "scheduled"}} = request, reason, state) do
    {{:error, reason}, ledger_cloud_block(request, reason, state)}
  end

  defp block_or_error_cloud(_request, reason, state), do: {{:error, reason}, state}

  defp ledger_cloud_block(request, reason, state) do
    run_id = Ledger.generate_id()

    case Ledger.admit(cloud_admit_attrs(request, run_id, "submitting", state), server: state.repo) do
      {:ok, _row} -> terminalize_and_notify(state, run_id, block_outcome(reason), nil)
      {:error, admit_error} -> log_block_unledgered(run_id, reason, admit_error, state)
    end
  end

  defp cloud_admit_attrs(request, run_id, status, state) do
    snapshot = request.snapshot
    marker = "cloud:" <> Map.fetch!(request.params, :env_id)

    %{
      id: run_id,
      vendor: "codex_cloud",
      rail: "cloud",
      status: status,
      cwd: marker,
      worktree_root: marker,
      lock_roots: [],
      artifacts_dir: artifacts_dir_for(run_id, state.artifacts_opts),
      resumable: false,
      origin_kind: Map.fetch!(snapshot, :origin_kind),
      origin_session_id: request.origin_session_id,
      continuation_depth: Map.get(request, :continuation_depth, 0),
      parent_job_id: Map.get(snapshot, :parent_job_id),
      delivery_mode: Map.fetch!(snapshot, :delivery_mode),
      platform: Map.get(snapshot, :platform),
      destination: Map.get(snapshot, :destination),
      thread: Map.get(snapshot, :thread),
      send_opts: Map.get(snapshot, :send_opts)
    }
  end

  # --- Cloud polling ------------------------------------------------------

  defp poll_tick(state, run_id) do
    case Map.get(state.runs, run_id) do
      %{cloud: true} = info -> run_poll(state, run_id, info)
      _absent_or_local -> state
    end
  end

  defp run_poll(state, run_id, info) do
    now = state.now_fn.()

    if deadline_passed?(info.poll_deadline, now) do
      cloud_terminalize(state, run_id, poll_deadline_outcome(), info)
    else
      execute_poll(state, run_id, info)
    end
  end

  defp execute_poll(state, run_id, info) do
    case cloud_status(info, state) do
      {:ok, %{exit: code, stdout: out}} -> apply_status(state, run_id, info, out, code)
      {:error, reason} -> poll_error(state, run_id, info, "status:#{inspect(reason)}")
    end
  end

  defp cloud_status(info, state) do
    with {:ok, binary} <- Vendors.binary("codex", find_executable: info.find_executable),
         {:ok, built} <- cloud_built(binary, ["cloud", "status", info.task_id], state) do
      run_cloud_command(built, info.artifacts_dir, state.cloud_status_timeout_ms, state)
    end
  end

  defp apply_status(state, run_id, info, out, code) do
    case CodexCloud.parse_status(out, code) do
      {:ok, view} -> apply_disposition(state, run_id, info, view)
      # D19: the pinned `Not signed in.` diagnostic at poll → immediate blocked.
      {:error, :cloud_auth} -> cloud_terminalize(state, run_id, cloud_auth_outcome(), info)
      {:error, {:command_failed, detail}} -> poll_error(state, run_id, info, detail)
      {:error, {:status_parse, detail}} -> poll_error(state, run_id, info, detail)
    end
  end

  defp apply_disposition(state, run_id, info, view) do
    case CodexCloud.ledger_mapping(view.state) do
      :nonterminal ->
        reschedule(state, run_id, info)

      {:terminal, _status, _reason, _note} ->
        cloud_terminalize(state, run_id, cloud_status_outcome(view), info)
    end
  end

  # A poll command/parse error is bounded by the poll deadline (not a separate
  # budget): count it for observability and re-arm; the next tick's deadline check
  # ends the run. Never scraped heuristically — an unrecognized status is a parse
  # failure, not a guessed state (Rule 12).
  defp poll_error(state, run_id, info, detail) do
    Logger.debug("harness cloud run #{run_id} poll error: #{detail}")
    reschedule(state, run_id, %{info | poll_errors: info.poll_errors + 1})
  end

  defp reschedule(state, run_id, info) do
    now = state.now_fn.()
    next = DateTime.add(now, state.cloud_poll_ms, :millisecond)

    _ =
      Ledger.record_progress(run_id, %{next_poll_at: next, last_event_at: now},
        server: state.repo
      )

    put_and_arm(state, run_id, info, state.cloud_poll_ms)
  end

  defp put_and_arm(state, run_id, info, delay_ms) do
    timer = Process.send_after(self(), {:cloud_poll, run_id}, max(delay_ms, 0))
    put_run(state, run_id, %{info | timer: timer})
  end

  defp cloud_terminalize(state, run_id, outcome, info) do
    cancel_timer(info.timer)
    terminalize_and_notify(state, run_id, outcome, info)
  end

  defp deadline_passed?(nil, _now), do: false
  defp deadline_passed?(%DateTime{} = deadline, now), do: DateTime.compare(now, deadline) != :lt

  # --- Cloud stop-tracking ------------------------------------------------

  defp stop_tracking_call(run_id, state) do
    case Map.get(state.runs, run_id) do
      %{cloud: true} = info ->
        {:reply, {:ok, info.task_url},
         cloud_terminalize(state, run_id, tracking_stopped_outcome(), info)}

      %{} = _local ->
        {:reply, {:error, :not_cloud}, state}

      nil ->
        stop_tracking_absent(run_id, state)
    end
  end

  # A cloud row not in the tracking map is normally terminal (→ `:already_terminal`).
  # But a boot reconciliation scan failure can leave an ACTIVE cloud row unarmed and
  # untracked; honor the owner's stop by terminalizing it here (there is no timer to
  # cancel) and hand back its task URL — never a false "already finished".
  defp stop_tracking_absent(run_id, state) do
    case Ledger.get(run_id, server: state.repo) do
      {:ok, %{rail: "cloud", status: status} = row} when status in ["submitting", "polling"] ->
        {:reply, {:ok, Map.get(row, :task_url)},
         terminalize_and_notify(state, run_id, tracking_stopped_outcome(), nil)}

      {:ok, %{rail: "cloud"}} ->
        {:reply, {:error, :already_terminal}, state}

      {:ok, _local} ->
        {:reply, {:error, :not_cloud}, state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}

      {:error, _reason} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # --- Cloud command execution (env -i, isolated) -------------------------

  defp cloud_command(binary, argv, cwd, state) do
    case cloud_built(binary, argv, state) do
      {:ok, built} -> run_cloud_command(built, cwd, state.cloud_submit_timeout_ms, state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp cloud_built(binary, argv, state) do
    case Env.build(binary, argv, codex_home_env(),
           home: cloud_home(state),
           path: cloud_path(state),
           user: cloud_user(state)
         ) do
      {:ok, built} -> {:ok, built}
      {:error, reason} -> {:error, {:env, reason}}
    end
  end

  defp run_cloud_command(built, cwd, timeout_ms, state) do
    CommandRunner.run(built.executable, built.args,
      cwd: cwd,
      timeout_ms: timeout_ms,
      supervised: true,
      dynamic_supervisor: state.command_supervisor
    )
  end

  defp codex_home_env do
    case Config.codex_home() do
      home when is_binary(home) and home != "" -> %{"CODEX_HOME" => home}
      _absent -> %{}
    end
  end

  defp cloud_home(state), do: state.home || System.get_env("HOME") || System.user_home!()
  defp cloud_path(state), do: state.path || System.get_env("PATH") || "/usr/bin:/bin"
  defp cloud_user(state), do: state.user || System.get_env("USER")

  # --- Cloud outcomes -----------------------------------------------------

  defp cloud_status_outcome(view) do
    {:terminal, status, reason, note} = CodexCloud.ledger_mapping(view.state)
    diagnostics = cloud_diagnostics(view, note)

    %{
      status: status,
      ledger_fields: reject_nil(%{reason: reason_string(reason), diagnostics_tail: diagnostics}),
      result_text: nil,
      error_class: cloud_error_class(status, reason)
    }
  end

  defp cloud_diagnostics(view, note) do
    [vendor_status_summary(view), note]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp vendor_status_summary(%{raw: raw}) do
    ["vendor status: #{String.downcase(raw.status)}", diff_summary(raw)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp diff_summary(%{diff: %{adds: adds, dels: dels, files: files}}) do
    "+#{adds}/-#{dels} · #{files} file#{plural(files)}"
  end

  defp diff_summary(%{diff: :none}), do: "no diff"
  defp diff_summary(_raw), do: ""

  defp plural(1), do: ""
  defp plural(_n), do: "s"

  defp reason_string(nil), do: nil
  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp cloud_error_class("completed", _reason), do: nil
  defp cloud_error_class(_status, reason), do: reason_string(reason)

  defp poll_deadline_outcome do
    cloud_block("poll_deadline", "Polling deadline reached with no terminal vendor status.")
  end

  defp tracking_stopped_outcome do
    cloud_block(
      "tracking_stopped",
      "Stopped tracking this cloud task. The vendor task itself keeps running — check it on ChatGPT."
    )
  end

  defp cloud_auth_outcome do
    cloud_block("cloud_auth", "Not signed in to ChatGPT — run `codex login`, then resubmit.")
  end

  defp submit_failed_outcome(detail) do
    cloud_block("submit_failed", detail)
  end

  defp submission_unknown_outcome(row) do
    cloud_block("submission_outcome_unknown", submission_unknown_detail(row))
  end

  # The submit succeeded and created a live vendor task, but its poll schedule
  # could not be persisted, so tracking cannot continue. The `submission_outcome_
  # unknown` bucket (§5.3 / §12.1) is the honest terminal for a live cloud task we
  # can no longer track: carry the known `task_id`/`task_url` so the delivery still
  # points at the task (the composer renders the URL + `codex cloud diff` hint),
  # and tell the owner it keeps running and is never auto-resubmitted.
  defp tracking_lost_outcome(task_id, task_url, detail) do
    %{
      status: "blocked",
      ledger_fields:
        reject_nil(%{
          reason: "submission_outcome_unknown",
          task_id: task_id,
          task_url: task_url,
          diagnostics_tail:
            "The Codex cloud task was created but its poll schedule could not be " <>
              "persisted (#{detail}), so tracking stopped. The task keeps running — " <>
              "inspect `codex cloud list`; it is never auto-resubmitted."
        }),
      result_text: nil,
      error_class: "submission_outcome_unknown"
    }
  end

  defp cloud_block(reason, diagnostics) do
    %{
      status: "blocked",
      ledger_fields: reject_nil(%{reason: reason, diagnostics_tail: diagnostics}),
      result_text: nil,
      error_class: reason
    }
  end

  defp submission_unknown_detail(row) do
    env_id = String.replace_prefix(Map.get(row, :cwd, ""), "cloud:", "")

    "Submission outcome unknown — the daemon restarted mid-submit. " <>
      "env: #{env_id}. created: #{iso(Map.get(row, :created_at))}. " <>
      "query: #{reconciled_query(row)}. " <>
      "Inspect `codex cloud list` to see whether a task was created; this run is never auto-resubmitted."
  end

  defp reconciled_query(row) do
    case File.read(Path.join(Map.get(row, :artifacts_dir, ""), @cloud_prompt_file)) do
      {:ok, query} when query != "" -> String.slice(query, 0, 512)
      _absent_or_empty -> "(query snapshot unavailable)"
    end
  end

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(_value), do: "unknown"

  # --- Cloud state helpers ------------------------------------------------

  defp cloud_info(row, state, fields) do
    %{
      cloud: true,
      timer: nil,
      poll_errors: 0,
      artifacts_dir: cloud_artifacts_dir(row, state)
    }
    |> Map.merge(fields)
  end

  defp cloud_artifacts_dir(row, state) do
    Map.get(row, :artifacts_dir) || artifacts_dir_for(row.id, state.artifacts_opts)
  end

  defp cloud_query(request), do: Map.fetch!(request.params, :query)

  # Both rails read one argv cap: the local rail uses `Config.prompt_argv_max_kb`
  # via `Harness.Prompt`; the cloud rail passes the same configured value here so a
  # config change applies to both (no half-applied knob).
  defp cloud_submit_opts(request, state) do
    [max_query_bytes: state.cloud_query_max_bytes] ++ cloud_find_executable_opts(request.ctx)
  end

  defp cloud_find_executable_opts(ctx) do
    case Map.get(ctx, :find_executable) do
      fun when is_function(fun, 1) -> [find_executable: fun]
      _absent -> []
    end
  end

  defp cloud_find_executable(ctx, state) do
    case Map.get(ctx, :find_executable) do
      fun when is_function(fun, 1) -> fun
      _absent -> state.default_find_executable
    end
  end

  # --- Cancel -------------------------------------------------------------

  defp request_cancel(run_info) do
    Run.cancel(run_info.pid, :owner)
    :ok
  end

  defp terminal_cancel_reply(run_id, state) do
    case Ledger.get(run_id, server: state.repo) do
      {:ok, _row} -> {:error, :already_terminal}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # --- Terminalization ----------------------------------------------------

  defp finalize_reported(state, run_id, status, fields) do
    case Map.get(state.runs, run_id) do
      nil ->
        log_unknown_report(run_id, state)

      run_info ->
        terminalize_and_notify(state, run_id, reported_outcome(status, fields), run_info)
    end
  end

  defp log_unknown_report(run_id, state) do
    Logger.debug(
      "harness terminal report for untracked run #{run_id} ignored (already finalized)"
    )

    state
  end

  defp handle_down(ref, reason, state) do
    case Map.pop(state.run_monitors, ref) do
      {nil, monitors} -> %{state | run_monitors: monitors}
      {_run_id, monitors} when reason in [:normal, :shutdown] -> %{state | run_monitors: monitors}
      {run_id, monitors} -> mark_run_crashed(run_id, %{state | run_monitors: monitors})
    end
  end

  defp mark_run_crashed(run_id, state) do
    case Map.get(state.runs, run_id) do
      nil -> state
      run_info -> terminalize_and_notify(state, run_id, crash_outcome(), run_info)
    end
  end

  defp terminalize_and_notify(state, run_id, outcome, run_info) do
    case Ledger.terminalize(run_id, outcome.status, outcome.ledger_fields, server: state.repo) do
      {:ok, row} -> post_terminal(state, run_id, row, outcome, run_info)
      {:error, :already_terminal} -> resolve_after_race(state, run_id, run_info)
      {:error, reason} -> after_terminalize_error(state, run_id, reason, run_info)
    end
  end

  # A tracked cloud run whose terminal write hit a transient ledger error: the
  # vendor task is still live, so re-arm the poll (paced by the poll interval,
  # bounded by `poll_deadline`; a restart also re-arms the persisted row) rather
  # than drop it — the next tick re-derives the terminal outcome and retries the
  # write. Never stop polling a live cloud task without a terminal row. A local
  # run (or a `nil` submit-time run_info) has no live poll to re-arm and is dropped.
  defp after_terminalize_error(state, run_id, _reason, %{cloud: true} = info) do
    Logger.warning("harness cloud run #{run_id} terminalize failed; re-arming poll")
    put_and_arm(state, run_id, info, state.cloud_poll_ms)
  end

  defp after_terminalize_error(state, run_id, reason, run_info) do
    log_terminalize_error(state, run_id, reason, run_info)
  end

  defp post_terminal(state, run_id, row, outcome, run_info) do
    emit_terminal_telemetry(row, outcome)
    MemoryWriteback.write(row, outcome.result_text, repo: state.repo)
    hand_off_outcome(row, outcome, state)
    drop_run(state, run_id, run_info)
  end

  defp emit_terminal_telemetry(row, %{error_class: nil, result_text: result_text}) do
    Telemetry.run_complete(row, result_text)
  end

  defp emit_terminal_telemetry(row, %{error_class: error_class}) do
    Telemetry.run_error(row, error_class)
  end

  # A run whose terminal race the crash path already won: drop it — never
  # re-deliver and never re-continue (the winning path already handed the
  # outcome off).
  defp resolve_after_race(state, run_id, run_info) do
    drop_run(state, run_id, run_info)
  end

  defp log_terminalize_error(state, run_id, reason, run_info) do
    Logger.error("harness run #{run_id} terminalize failed: #{inspect(reason)}")
    drop_run(state, run_id, run_info)
  end

  # The terminal outcome hand-off (§23.2). A chat-origin run inside the chain cap
  # re-enters its conversation: on a successful dispatch the row is marked
  # `delivered` (the agent's turn IS the notification — no text push, no
  # double-notify); on a failed dispatch the row stays `pending` so the
  # DeliveryWorker delivers the text. Everything else — scheduled/cron origins, a
  # depth-capped chain, a host with no dispatcher configured — takes the plain
  # inline delivery attempt of §9.1.
  defp hand_off_outcome(row, outcome, state) do
    case continuation_dispatcher(row, state) do
      {:ok, dispatcher} -> continue_or_pend(row, outcome, dispatcher, state)
      :none -> deliver_and_mark(row, state)
    end
  end

  defp continuation_dispatcher(row, state) do
    if Continuation.continuable?(row) do
      Continuation.dispatcher(state.continuation_opts)
    else
      :none
    end
  end

  defp continue_or_pend(row, outcome, dispatcher, state) do
    case Continuation.dispatch(dispatcher, row, outcome.result_text) do
      :ok -> mark_continued(row, state)
      {:error, reason} -> log_continuation_failed(row, reason)
    end
  end

  defp mark_continued(row, state) do
    Logger.info(
      "harness run #{row.id} continued into its conversation " <>
        "(depth #{Continuation.next_depth(row)}); no text delivery"
    )

    mark_delivered(row, state)
  end

  # Left `pending` on purpose: the durable outbox is the at-least-once path, so
  # the DeliveryWorker's next tick delivers the outcome as text.
  defp log_continuation_failed(row, reason) do
    Logger.warning(
      "harness continuation dispatch failed for #{row.id}: #{inspect(reason)}; " <>
        "delivery left pending for the worker"
    )

    :ok
  end

  defp deliver_and_mark(row, state) do
    case Delivery.deliver(row, state.delivery_opts) do
      {:ok, _sent_or_skipped} -> mark_delivered(row, state)
      {:error, reason} -> log_delivery_failed(row, reason)
    end
  end

  defp mark_delivered(row, state) do
    fields = %{delivery_status: "delivered", delivered_at: state.now_fn.()}

    case Ledger.mark_delivery(row.id, fields, server: state.repo) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("harness mark-delivered failed for #{row.id}: #{inspect(reason)}")
    end
  end

  defp log_delivery_failed(row, reason) do
    Logger.warning("harness inline delivery failed for #{row.id}: #{inspect(reason)}")
    :ok
  end

  defp drop_run(state, run_id, nil) do
    %{state | runs: Map.delete(state.runs, run_id)}
  end

  # A cloud run holds no OS-process monitor (its liveness is the poll timer, already
  # cancelled by the terminalizer) — drop it from `runs` alone.
  defp drop_run(state, run_id, %{cloud: true}) do
    %{state | runs: Map.delete(state.runs, run_id)}
  end

  defp drop_run(state, run_id, run_info) do
    %{
      state
      | runs: Map.delete(state.runs, run_id),
        run_monitors: Map.delete(state.run_monitors, run_info.ref)
    }
  end

  # --- Outcomes -----------------------------------------------------------

  defp reported_outcome(status, fields) do
    %{
      status: status,
      ledger_fields: reported_ledger_fields(fields),
      result_text: Map.get(fields, :result_text),
      error_class: reported_error_class(status, fields)
    }
  end

  defp reported_ledger_fields(fields) do
    %{
      reason: Map.get(fields, :reason),
      exit_code: Map.get(fields, :exit_code),
      framing_errors: Map.get(fields, :framing_errors),
      diagnostics_tail: join_diagnostics(Map.get(fields, :diagnostics_tail)),
      vendor_session_id: Map.get(fields, :vendor_session_id),
      artifact_truncated: Map.get(fields, :artifact_truncated),
      usage: Map.get(fields, :usage)
    }
    |> reject_nil()
  end

  defp reported_error_class("completed", _fields), do: nil
  defp reported_error_class(status, fields), do: Map.get(fields, :reason) || status

  defp crash_outcome do
    %{
      status: "failed",
      ledger_fields: %{reason: "run_crashed"},
      result_text: nil,
      error_class: "run_crashed"
    }
  end

  defp interrupted_outcome do
    %{status: "interrupted", ledger_fields: %{}, result_text: nil, error_class: "interrupted"}
  end

  # The consent block carries the approve-coding-agents guidance in its
  # diagnostics tail so the delivered message tells the owner how to unblock
  # (design §22) — the wording lives in `Consent`, the single source.
  defp block_outcome(:consent_required) do
    %{
      status: "blocked",
      ledger_fields: %{reason: "consent_required", diagnostics_tail: Consent.scheduled_guidance()},
      result_text: nil,
      error_class: "consent_required"
    }
  end

  defp block_outcome(reason) do
    class = block_reason_string(reason)
    %{status: "blocked", ledger_fields: %{reason: class}, result_text: nil, error_class: class}
  end

  defp block_reason_string(:cli_unavailable), do: "cli_unavailable"
  defp block_reason_string({:artifact_quota, _detail}), do: "artifact_quota"
  defp block_reason_string(:workspace_denied), do: "workspace_denied"

  defp join_diagnostics([]), do: nil
  defp join_diagnostics(lines) when is_list(lines), do: Enum.join(lines, "\n")
  defp join_diagnostics(other), do: other

  defp reject_nil(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  # --- Reconciliation + GC ------------------------------------------------

  defp reconcile(state) do
    case Ledger.active_runs(server: state.repo) do
      {:ok, rows} -> Enum.reduce(rows, state, &reconcile_row/2)
      {:error, reason} -> log_reconcile_scan_error(reason, state)
    end
  end

  defp reconcile_row(%{rail: "local", status: status} = row, state)
       when status in ["starting", "running"] do
    terminalize_and_notify(state, row.id, interrupted_outcome(), nil)
  end

  # A cloud `submitting` row WITHOUT a task id: the daemon may have died after the
  # remote task was created but before its id persisted. Finalize the unknown
  # outcome + deliver the recovery guidance; NEVER auto-resubmit (§5.3).
  defp reconcile_row(%{rail: "cloud", status: "submitting", task_id: nil} = row, state) do
    terminalize_and_notify(state, row.id, submission_unknown_outcome(row), nil)
  end

  # A cloud `submitting` row WITH a task id (a crash between persist and status
  # flip): promote it to polling and re-arm.
  defp reconcile_row(%{rail: "cloud", status: "submitting", task_id: task_id} = row, state)
       when is_binary(task_id) do
    promote_and_arm(state, row)
  end

  # A cloud `polling` row: re-arm from its persisted `next_poll_at`/`poll_deadline`.
  defp reconcile_row(%{rail: "cloud", status: "polling"} = row, state) do
    arm_reconciled_poll(state, row, cloud_info_from_row(row, state))
  end

  defp reconcile_row(row, state) do
    Logger.warning(
      "harness reconciliation found unsupported row #{row.id} " <>
        "(status=#{row.status} rail=#{row.rail}); left untouched"
    )

    state
  end

  defp promote_and_arm(state, row) do
    now = state.now_fn.()

    fields = %{
      task_id: row.task_id,
      task_url: row.task_url,
      next_poll_at: DateTime.add(now, state.cloud_poll_ms, :millisecond),
      poll_deadline: row.poll_deadline || DateTime.add(now, state.cloud_poll_max_ms, :millisecond)
    }

    case Ledger.mark_polling(row.id, fields, server: state.repo) do
      {:ok, promoted} ->
        arm_reconciled_poll(state, promoted, cloud_info_from_row(promoted, state))

      # The promote write failed at boot (a transient ledger error). A live vendor
      # task exists (this row carries its `task_id`), so do NOT leave it active but
      # unpolled and untracked: terminalize the tracking-lost outcome carrying the
      # task URL (releasing the capacity slot, making `stop_tracking` honest) and
      # never auto-resubmit.
      {:error, reason} ->
        terminalize_and_notify(
          state,
          row.id,
          tracking_lost_outcome(row.task_id, row.task_url, "mark_polling:#{inspect(reason)}"),
          nil
        )
    end
  end

  # Past the deadline → blocked immediately; otherwise arm from the persisted
  # `next_poll_at` (a past-due schedule ticks at once, `max(delay, 0)`).
  defp arm_reconciled_poll(state, row, info) do
    now = state.now_fn.()

    if deadline_passed?(info.poll_deadline, now) do
      cloud_terminalize(state, row.id, poll_deadline_outcome(), info)
    else
      put_and_arm(state, row.id, info, poll_delay(row.next_poll_at, now))
    end
  end

  defp poll_delay(%DateTime{} = next_poll_at, now),
    do: DateTime.diff(next_poll_at, now, :millisecond)

  defp poll_delay(_absent, _now), do: 0

  defp cloud_info_from_row(row, state) do
    cloud_info(row, state, %{
      task_id: row.task_id,
      task_url: row.task_url,
      poll_deadline: row.poll_deadline,
      find_executable: state.default_find_executable
    })
  end

  defp log_reconcile_scan_error(reason, state) do
    Logger.warning("harness boot reconciliation scan failed: #{inspect(reason)}")
    state
  end

  defp run_gc(state) do
    _ = Artifacts.gc(state.now_fn.(), state.artifacts_opts)
    state
  end

  defp arm_gc_timer(%{timer_enabled?: false} = state), do: state

  defp arm_gc_timer(state) do
    cancel_timer(state.gc_timer)
    %{state | gc_timer: Process.send_after(self(), :harness_gc, state.gc_interval_ms)}
  end

  # --- State --------------------------------------------------------------

  defp normalize_request(request) do
    %{
      vendor: Map.fetch!(request, :vendor),
      adapter: Map.fetch!(request, :adapter),
      prompt: Map.fetch!(request, :prompt),
      cwd: Map.fetch!(request, :cwd),
      ctx: Map.get(request, :ctx, %{}),
      params: Map.get(request, :params, %{}),
      snapshot: Map.fetch!(request, :snapshot),
      origin_session_id: Map.fetch!(request, :origin_session_id),
      # Normalize the optional deadline once here (nil ⇒ the config default), so
      # neither the telemetry nor the Run's `timeout_minutes * 60_000` ever sees a
      # present-but-nil key.
      timeout_minutes: Map.get(request, :timeout_minutes) || Config.default_timeout_minutes(),
      progress: Map.get(request, :progress, :quiet),
      continuation_depth: Map.get(request, :continuation_depth, 0)
    }
  end

  defp build_state(opts) do
    %{
      repo: Keyword.get(opts, :repo, Repo),
      run_supervisor: Keyword.get(opts, :run_supervisor, RunSupervisor),
      command_supervisor: Keyword.get(opts, :command_supervisor, CommandHostSupervisor),
      artifacts_opts: Keyword.get(opts, :artifacts_opts, []),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      # Completion-continuation seam (§23.2): the channels-side dispatcher module,
      # injected per-instance by tests and resolved from app env otherwise (the
      # `Delivery.ChannelSend` adapter precedent).
      continuation_opts: [dispatcher: Keyword.get(opts, :continuation_dispatcher)],
      timer_enabled?: Keyword.get(opts, :timer_enabled, true),
      gc_interval_ms: Keyword.get(opts, :gc_interval_ms, @default_gc_interval_ms),
      now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0),
      # Cloud poll cadence and submit/status wall clocks. Config holds seconds/
      # minutes; the manager works in ms and takes injectable scales so tests drive
      # poll cycles without wall-clock waits (the DeliveryWorker seam precedent).
      cloud_poll_ms: Keyword.get(opts, :cloud_poll_ms, Config.cloud_poll_seconds() * 1_000),
      cloud_poll_max_ms:
        Keyword.get(opts, :cloud_poll_max_ms, Config.cloud_poll_max_minutes() * 60_000),
      cloud_query_max_bytes:
        Keyword.get(opts, :cloud_query_max_bytes, Config.prompt_argv_max_kb() * 1_024),
      cloud_submit_timeout_ms:
        Keyword.get(opts, :cloud_submit_timeout_ms, @cloud_submit_timeout_ms),
      cloud_status_timeout_ms:
        Keyword.get(opts, :cloud_status_timeout_ms, @cloud_status_timeout_ms),
      default_find_executable: Keyword.get(opts, :find_executable, &System.find_executable/1),
      home: Keyword.get(opts, :home),
      path: Keyword.get(opts, :path),
      user: Keyword.get(opts, :user),
      runs: %{},
      run_monitors: %{},
      gc_timer: nil
    }
  end

  defp normalize_cloud_request(request) do
    %{
      params: Map.fetch!(request, :params),
      snapshot: Map.fetch!(request, :snapshot),
      origin_session_id: Map.fetch!(request, :origin_session_id),
      ctx: Map.get(request, :ctx, %{}),
      continuation_depth: Map.get(request, :continuation_depth, 0)
    }
  end

  defp put_run(state, run_id, run_info) do
    %{state | runs: Map.put(state.runs, run_id, run_info)}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end
