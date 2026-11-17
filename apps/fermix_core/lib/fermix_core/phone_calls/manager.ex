defmodule FermixCore.PhoneCalls.Manager do
  @moduledoc """
  The one permanent owner of phone-call admission, terminalization and
  reconciliation (M94 §04, §09, §12), the `Harness.Manager` shape. Its
  callbacks are thin and it never waits in one: every network step (a call's
  dial, a hang-up request, a report's send) runs in another process, and the
  ledger is its only blocking dependency.

    * **Admission (`start_call/2`).** Admission open (`disable/1` closes it),
      readiness re-read on every start (`Readiness.current/0`: enablement,
      role, durable memory and every setting the call needs, so a caller
      holding an old tool list is still refused), the server-owned
      authorization evidence present and matching the brief, then
      `Ledger.admit/3` (the request's own call, the slot, the day's attempts,
      one transaction). Only then does a worker start, as a `:temporary` child
      of `PhoneCalls.CallSupervisor`, monitored, and the single `run_start`
      event is emitted. The answer means accepted here, never answered.
    * **The single terminal writer.** A worker reports its end with one
      message (`report_end/3`); this process writes the terminal row once,
      leasing the report to the hand-off (`@handoff_lease_ms`), emits the
      closer, and runs the hand-off (`PhoneCalls.Delivery.hand_off/2`) in a
      task of `PhoneCalls.HandoffSupervisor`.
    * **A lost worker** (its DOWN arrives with no end report) and **boot
      reconciliation** (every non-terminal row, in `handle_continue`) are
      settled by what the row proves (`settle/3`): never dispatched → `failed`,
      nothing dialed; dispatch claimed with no session id → `dispatch_unknown`;
      a known provider session → `closure_unconfirmed` and one cleanup request
      for that session through the injected `:hangup`, asynchronously.
      Nothing is ever redialed, and supervision never restarts a worker.
    * **Cancel (`cancel/3`)** stops new work: a call not yet dispatched ends at
      once with nothing dialed (its later dispatch claim fails); a dispatched
      one is asked to stop and reads `stopping` until its end is known.
    * **The off switch (`disable/1`)**, serialized with admission here: no new
      start, admitted work that has not dispatched ends with nothing dialed,
      a live call is asked to stop. Cleanup, status, recovery and report
      delivery stay alive. `enable/1` reopens admission and nothing else: it
      releases no uncertain slot and redials nothing.

  ## The worker contract

  The worker module is the required `:call_module` option (no default). The
  Manager starts it, under `PhoneCalls.CallSupervisor` with a child spec it
  builds itself (`restart: :temporary`), as `call_module.start_link(args)`:

      %{
        call_id: String.t(),            # "pc_" + 12 hex
        row: map(),                     # the admitted ledger row
        brief: PhoneCalls.Brief.t(),    # the validated mandate
        manager: pid(),                 # where report_end/3 goes
        repo: GenServer.server(),       # the ledger's server: pass as `server:`
        now_fn: (-> DateTime.t()),
        session_id: String.t(),         # "phone_call_" <> call_id, its turns' too
        parent_session: String.t()      # the requesting turn's session
      }

  It must also export `cancel(pid, :owner | :disabled) :: :ok`, asynchronous
  (the Manager never waits on it), after which it stops new work, requests the
  hang-up of a known session, drains, and reports; and `prompt_version/0`, the
  version of its telephone instructions, snapshotted on the row at admission.

  It writes its own non-terminal steps through `PhoneCalls.Ledger` with
  `server: repo`, each guarded: `claim_dispatch/3` immediately before the one
  create request, which it sends only on `{:ok, _}` (a row cancelled or
  disabled first answers `{:error, {:not_admitted, status}}`);
  `record_session/4` as soon as the create returns a session id, before
  attaching; `record_carrier_call/3` only for a carrier id the carrier
  reported; `advance/4` for ringing, answered and closing; `consume/3` before
  each backend turn, keypad key or cleanup attempt, acting only on `{:ok, _}`;
  `record_usage/4` for each cumulative usage snapshot. It never writes a
  terminal row. It ends with exactly one `report_end/3`, whose report is

      %{
        status: "ended" | "failed" | "dispatch_unknown" | "closure_unconfirmed",
        outcome: "confirmed" | "unavailable" | "options" | "needs_owner" | "unknown",
        outcome_facts: map() | nil,
        evidence: [%{speaker: String.t(), text: String.t()}],
        usage: map() | nil,
        voice_seconds: non_neg_integer() | nil,
        usage_state: "voice_duration_confirmed" | "incomplete",
        backend_usage: map() | nil,
        failure_reason: String.t() | nil,
        vendor_message: String.t() | nil
      }

  and then exits. A report the ledger refuses (say, `confirmed` with no
  evidence) is settled as a lost worker. A worker that exits without a report,
  whatever the exit reason, is settled by what its row proves.
  """

  use GenServer

  require Logger

  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.CarrierProfile
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Delivery
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Readiness
  alias FermixCore.PhoneCalls.Report
  alias FermixCore.PhoneCalls.Telemetry

  @start_call_timeout_ms 15_000
  @default_prune_interval_ms 86_400_000
  # The terminal write leases the report to the hand-off task before the
  # DeliveryWorker may select it. The hand-off is at most a continuation
  # dispatch (15 s watchdog), one inline send (60 s watchdog) and two ledger
  # writes (5 s each): 85 s, so 120 s leaves margin. A sleep or clock jump
  # past the lease is the designed at-least-once duplicate notification.
  @handoff_lease_ms 120_000
  @end_statuses ~w(ended failed dispatch_unknown closure_unconfirmed)
  @report_keys [
    :outcome,
    :outcome_facts,
    :evidence,
    :usage,
    :voice_seconds,
    :usage_state,
    :backend_usage,
    :failure_reason,
    :vendor_message
  ]

  @type request :: %{
          required(:brief) => Brief.t(),
          required(:brief_hash) => String.t(),
          required(:request_id) => String.t(),
          required(:owner_id) => String.t(),
          required(:operation) => String.t(),
          required(:authorization) => String.t(),
          optional(:access_intent) => String.t() | nil,
          required(:snapshot) => Delivery.snapshot()
        }

  @type started :: %{call_id: String.t(), state: String.t(), reused: boolean()}

  # --- public API -----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Admits a call and starts its worker; answers its id and admission state.
  Refusals: `:disabled`, `{:needs_setup, reasons}`, `{:authorization_evidence,
  field}`, `{:slot_held, call_id}`, `{:daily_attempts_exhausted, n}`,
  `{:call_start_failed, reason}`, or the ledger's own error. The same request
  again answers its existing call with `reused: true`.
  """
  @spec start_call(request(), GenServer.server()) :: {:ok, started()} | {:error, term()}
  def start_call(request, server \\ __MODULE__) when is_map(request) do
    GenServer.call(server, {:start_call, request}, @start_call_timeout_ms)
  end

  @doc """
  The owner's own call, as `PhoneCalls.Report.status_view/2` shows it; another
  owner's id is `:not_found`. A ledger read (`opts[:repo]`, `opts[:now]`), not
  a call into this process.
  """
  @spec status(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(call_id, owner_id, opts \\ [])
      when is_binary(call_id) and is_binary(owner_id) and is_list(opts) do
    server = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, row} <- Ledger.get_for_owner(call_id, owner_id, server: server) do
      {:ok, Report.status_view(row, now)}
    end
  end

  @doc """
  The owner's stop. `{:ok, :cancelled}`: it had not dispatched and nothing was
  dialed; `{:ok, :stopping}`: a hang-up was asked for, and the call reads
  `stopping` until its end is known. `:not_found` for another owner's call,
  `:already_terminal` for a finished one.
  """
  @spec cancel(String.t(), String.t(), GenServer.server()) ::
          {:ok, :cancelled | :stopping} | {:error, term()}
  def cancel(call_id, owner_id, server \\ __MODULE__)
      when is_binary(call_id) and is_binary(owner_id) do
    GenServer.call(server, {:cancel, call_id, owner_id})
  end

  @doc "The off switch (see the moduledoc). Answers how many calls it ended and asked to stop."
  @spec disable(GenServer.server()) :: %{
          cancelled: non_neg_integer(),
          stopping: non_neg_integer()
        }
  def disable(server \\ __MODULE__), do: GenServer.call(server, :disable)

  @doc "Reopens admission. Releases no slot and redials nothing."
  @spec enable(GenServer.server()) :: :ok
  def enable(server \\ __MODULE__), do: GenServer.call(server, :enable)

  @doc """
  A worker's one end report (see the moduledoc), sent to the `manager` pid its
  start args name. A Manager that is gone receives nothing; its successor
  settles the row by what it proves.
  """
  @spec report_end(pid(), String.t(), map()) :: :ok
  def report_end(manager, call_id, report)
      when is_pid(manager) and is_binary(call_id) and is_map(report) do
    send(manager, {:phone_call_ended, call_id, report})
    :ok
  end

  @doc "How long the terminal write leases a report to the hand-off."
  @spec handoff_lease_ms() :: pos_integer()
  def handoff_lease_ms, do: @handoff_lease_ms

  # --- GenServer --------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, build_state(opts), {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, %{reconcile?: false} = state), do: {:noreply, state}

  def handle_continue(:reconcile, state) do
    {:noreply, state |> reconcile() |> prune() |> arm_prune()}
  end

  @impl true
  def handle_call({:start_call, request}, _from, state) do
    {reply, state} = admit(request, state)
    {:reply, reply, state}
  end

  def handle_call({:cancel, call_id, owner_id}, _from, state) do
    {reply, state} = cancel_call(call_id, owner_id, state)
    {:reply, reply, state}
  end

  def handle_call(:disable, _from, state) do
    {reply, state} = disable_calls(%{state | admission: :closed})
    {:reply, reply, state}
  end

  def handle_call(:enable, _from, state), do: {:reply, :ok, %{state | admission: :open}}

  @impl true
  def handle_info({:phone_call_ended, call_id, report}, state) do
    {:noreply, ended(call_id, report, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, down(ref, reason, state)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    {:noreply, cleanup_result(ref, result, state)}
  end

  def handle_info(:phone_call_prune, state), do: {:noreply, state |> prune() |> arm_prune()}

  def handle_info(_other, state), do: {:noreply, state}

  # --- admission ------------------------------------------------------------------

  defp admit(request, state) do
    with :ok <- admission_open(state),
         :ok <- ready(state),
         :ok <- check_evidence(request),
         {:ok, attrs} <- admission_attrs(request, state),
         {:ok, admission} <- Ledger.admit(attrs, now(state), server: state.repo) do
      start_admitted(admission, request.brief, state)
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp admission_open(%{admission: :open}), do: :ok
  defp admission_open(%{admission: :closed}), do: {:error, :disabled}

  defp ready(state) do
    case state.readiness.() do
      :ready -> :ok
      :disabled -> {:error, :disabled}
      {:needs_setup, reasons} -> {:error, {:needs_setup, reasons}}
    end
  end

  # The evidence is server-owned: the requesting turn's identity, the principal,
  # the operation and the hash of the very mandate it authorized. Model
  # arguments alone never satisfy it.
  defp check_evidence(request) do
    checks = [
      request_id: text?(Map.get(request, :request_id)),
      owner_id: text?(Map.get(request, :owner_id)),
      operation: Map.get(request, :operation) == "phone_call.start",
      authorization: Map.get(request, :authorization) in ~w(direct confirmed),
      brief_hash: brief_matches?(request)
    ]

    case Enum.find(checks, fn {_field, held?} -> not held? end) do
      nil -> :ok
      {field, false} -> {:error, {:authorization_evidence, field}}
    end
  end

  defp brief_matches?(%{brief: %Brief{} = brief, brief_hash: hash}) when is_binary(hash),
    do: Brief.hash(brief) == hash

  defp brief_matches?(_request), do: false

  defp admission_attrs(%{brief: brief, snapshot: snapshot} = request, state)
       when is_map(snapshot) do
    {:ok,
     Map.merge(
       Map.take(snapshot, [
         :origin_kind,
         :delivery_mode,
         :platform,
         :destination,
         :thread,
         :send_opts,
         :origin_conversation
       ]),
       %{
         request_id: request.request_id,
         owner_id: request.owner_id,
         authorization: request.authorization,
         access_intent: Map.get(request, :access_intent),
         mandate: Brief.to_map(brief),
         mandate_hash: Brief.hash(brief),
         model: CarrierProfile.model(),
         voice: state.config.().voice,
         prompt_version: state.call_module.prompt_version(),
         carrier_profile: CarrierProfile.id()
       }
     )}
  end

  defp admission_attrs(_request, _state), do: {:error, {:authorization_evidence, :snapshot}}

  defp start_admitted({:existing, row}, _brief, state) do
    {{:ok, %{call_id: row.id, state: row.status, reused: true}}, state}
  end

  defp start_admitted({:admitted, row}, brief, state) do
    case DynamicSupervisor.start_child(state.call_supervisor, child_spec(row, brief, state)) do
      {:ok, pid} ->
        {{:ok, %{call_id: row.id, state: row.status, reused: false}}, track(row, pid, state)}

      {:error, reason} ->
        start_failed(row, reason, state)
    end
  end

  # Built here, not by the worker module, so a worker is `:temporary` whatever
  # it declares: supervision never restarts one, and so never replays a dial.
  defp child_spec(row, brief, state) do
    args = %{
      call_id: row.id,
      row: row,
      brief: brief,
      manager: self(),
      repo: state.repo,
      now_fn: state.now_fn,
      session_id: Telemetry.session_id(row.id),
      parent_session: row.request_id
    }

    %{
      id: {:phone_call, row.id},
      start: {state.call_module, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  defp track(row, pid, state) do
    ref = Process.monitor(pid)
    Telemetry.run_start(row, max_duration_ms())

    %{
      state
      | calls: Map.put(state.calls, row.id, %{pid: pid, ref: ref}),
        monitors: Map.put(state.monitors, ref, row.id)
    }
  end

  # The Opik sweep floor: the call's own deadline, its drain and its one
  # result extraction.
  defp max_duration_ms,
    do:
      Limits.call_deadline_ms() + Limits.terminal_drain_ms() +
        Limits.result_extraction_timeout_ms()

  defp start_failed(row, reason, state) do
    Logger.error("phone call #{row.id} worker did not start: #{inspect(reason)}")
    state = fail_undispatched(row.id, "worker_start_failed", state)
    {{:error, {:call_start_failed, reason}}, state}
  end

  # --- terminal writes ---------------------------------------------------------------

  defp ended(call_id, report, state) do
    case Map.fetch(state.calls, call_id) do
      {:ok, _call} -> state |> untrack(call_id) |> write_report(call_id, report)
      :error -> log_untracked_report(call_id, state)
    end
  end

  defp log_untracked_report(call_id, state) do
    Logger.debug("phone call #{call_id} end report ignored: the call is not tracked")
    state
  end

  defp write_report(state, call_id, report) do
    case report_fields(report, state) do
      {:ok, status, fields} -> terminalize(call_id, status, fields, state)
      {:error, reason} -> refused_report(call_id, reason, state)
    end
  end

  defp report_fields(%{status: status} = report, state) when status in @end_statuses do
    fields =
      report
      |> Map.take(@report_keys)
      |> Map.merge(%{ended_at: now(state), next_delivery_at: lease_end(state)})

    {:ok, status, fields}
  end

  defp report_fields(report, _state), do: {:error, {:invalid, :status, Map.get(report, :status)}}

  defp terminalize(call_id, status, fields, state) do
    case Ledger.terminalize(call_id, status, fields, server: state.repo) do
      {:ok, row} -> post_terminal(row, state)
      {:error, :already_terminal} -> state
      {:error, {:invalid, _key, _value} = reason} -> refused_report(call_id, reason, state)
      {:error, reason} -> log_terminal_error(call_id, reason, state)
    end
  end

  defp refused_report(call_id, reason, state) do
    Logger.error(
      "phone call #{call_id} end report refused (#{inspect(reason)}); settling by its row"
    )

    settle_id(call_id, "invalid_end_report", state)
  end

  defp log_terminal_error(call_id, reason, state) do
    Logger.error("phone call #{call_id} terminal write failed: #{inspect(reason)}")
    state
  end

  defp fail_undispatched(call_id, reason, state) do
    opts = [server: state.repo, next_delivery_at: lease_end(state)]

    case Ledger.fail_undispatched(call_id, reason, now(state), opts) do
      {:ok, row} -> post_terminal(row, state)
      {:error, {:dispatched, _status}} -> settle_id(call_id, reason, state)
      {:error, :already_terminal} -> state
      {:error, other} -> log_terminal_error(call_id, other, state)
    end
  end

  # The closer, then the hand-off in a task of its own, so this process never
  # waits on a send. A task that cannot start leaves the report pending, and
  # the DeliveryWorker sends it once the lease ends.
  defp post_terminal(row, state) do
    Telemetry.run_end(row)

    opts = [
      repo: state.repo,
      now_fn: state.now_fn,
      delivery_opts: state.delivery_opts,
      continuation_opts: state.continuation_opts
    ]

    case Task.Supervisor.start_child(state.handoff_supervisor, fn ->
           Delivery.hand_off(row, opts)
         end) do
      {:ok, _pid} -> state
      {:error, reason} -> log_handoff_unstarted(row, reason, state)
    end
  end

  defp log_handoff_unstarted(row, reason, state) do
    Logger.warning(
      "phone call #{row.id} hand-off did not start (#{inspect(reason)}); the worker sends it"
    )

    state
  end

  # --- settling by what the row proves ----------------------------------------------

  defp down(ref, reason, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        cleanup_down(ref, reason, state)

      {call_id, monitors} ->
        lost_worker(call_id, reason, %{
          state
          | monitors: monitors,
            calls: Map.delete(state.calls, call_id)
        })
    end
  end

  defp lost_worker(call_id, reason, state) do
    Logger.warning("phone call #{call_id} worker ended without its report: #{inspect(reason)}")
    settle_id(call_id, "worker_lost", state)
  end

  defp settle_id(call_id, reason, state) do
    case Ledger.get(call_id, server: state.repo) do
      {:ok, row} -> settle(row, reason, state)
      {:error, other} -> log_terminal_error(call_id, other, state)
    end
  end

  # Only for a row no live worker owns. Never dispatched: nothing was dialed.
  # Claimed with no session id: whether the provider placed it is unknown, and
  # it is never dialed again. A known session: it may still be live, so its
  # end is unconfirmed and its hang-up is requested once.
  defp settle(%{status: "admitted"} = row, reason, state),
    do: fail_undispatched(row.id, reason, state)

  defp settle(%{status: status} = row, reason, state) do
    cond do
      Ledger.terminal?(status) ->
        state

      is_nil(row.provider_session_id) ->
        settle_terminal(row.id, "dispatch_unknown", reason, state)

      true ->
        row.id |> settle_terminal("closure_unconfirmed", reason, state) |> request_cleanup(row)
    end
  end

  defp settle_terminal(call_id, status, reason, state) do
    fields = %{
      outcome: "unknown",
      failure_reason: reason,
      ended_at: now(state),
      next_delivery_at: lease_end(state)
    }

    # Written directly, never through `terminalize/4`: a refused settlement is
    # logged, not settled again, so settling cannot recurse.
    case Ledger.terminalize(call_id, status, fields, server: state.repo) do
      {:ok, row} -> post_terminal(row, state)
      {:error, :already_terminal} -> state
      {:error, reason} -> log_terminal_error(call_id, reason, state)
    end
  end

  # One cleanup request for a known session, consumed on the row before the
  # request goes out, and run outside this process.
  defp request_cleanup(state, %{id: call_id, provider_session_id: session_id}) do
    with {:ok, _row} <- Ledger.consume(call_id, :cleanup_attempts, server: state.repo),
         %Task{ref: ref} <-
           Task.Supervisor.async_nolink(state.handoff_supervisor, fn ->
             state.hangup.(session_id)
           end) do
      %{state | cleanups: Map.put(state.cleanups, ref, call_id)}
    else
      other -> log_cleanup_unsent(call_id, other, state)
    end
  end

  defp log_cleanup_unsent(call_id, reason, state) do
    Logger.warning("phone call #{call_id} cleanup not requested: #{inspect(reason)}")
    state
  end

  defp cleanup_result(ref, result, state) do
    case Map.pop(state.cleanups, ref) do
      {nil, _cleanups} -> state
      {call_id, cleanups} -> record_cleanup(call_id, result, ref, %{state | cleanups: cleanups})
    end
  end

  defp record_cleanup(call_id, result, ref, state) do
    Process.demonitor(ref, [:flush])

    case result do
      :ok -> Logger.info("phone call #{call_id} hang-up requested for its known session")
      {:error, reason} -> record_cleanup_error(call_id, reason, state)
    end

    state
  end

  defp cleanup_down(ref, reason, state) do
    case Map.pop(state.cleanups, ref) do
      {nil, _cleanups} ->
        state

      {call_id, cleanups} ->
        record_cleanup_error(call_id, {:cleanup_crashed, reason}, %{state | cleanups: cleanups})
    end
  end

  defp record_cleanup_error(call_id, reason, state) do
    Logger.warning("phone call #{call_id} hang-up request failed: #{inspect(reason)}")

    case Ledger.record_cleanup_error(call_id, Delivery.bounded_error(reason), server: state.repo) do
      {:ok, _row} -> state
      {:error, other} -> log_terminal_error(call_id, other, state)
    end
  end

  # --- cancel and the off switch ----------------------------------------------------

  defp cancel_call(call_id, owner_id, state) do
    case Ledger.get_for_owner(call_id, owner_id, server: state.repo) do
      {:ok, row} -> cancel_row(row, :owner, state)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp cancel_row(%{status: status} = row, why, state) do
    cond do
      Ledger.terminal?(status) -> {{:error, :already_terminal}, state}
      Map.has_key?(state.calls, row.id) -> stop_tracked(row, why, state)
      true -> stop_untracked(row, why, state)
    end
  end

  # A tracked call not yet dispatched ends here with nothing dialed, guarded on
  # `admitted`: a worker that claimed its dispatch first wins, and the call is
  # then asked to stop instead. Either way the worker is told.
  defp stop_tracked(%{status: "admitted"} = row, why, state) do
    notify_worker(row.id, why, state)
    opts = [server: state.repo, next_delivery_at: lease_end(state)]

    case Ledger.fail_undispatched(row.id, stop_reason(why), now(state), opts) do
      {:ok, failed} -> {{:ok, :cancelled}, post_terminal(failed, state)}
      {:error, {:dispatched, _status}} -> {{:ok, :stopping}, mark_stopping(row.id, state)}
      {:error, :already_terminal} -> {{:error, :already_terminal}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp stop_tracked(row, why, state) do
    notify_worker(row.id, why, state)
    {{:ok, :stopping}, mark_stopping(row.id, state)}
  end

  defp mark_stopping(call_id, state) do
    case Ledger.mark_cancel_requested(call_id, now(state), server: state.repo) do
      {:ok, _row} -> state
      {:error, reason} -> log_terminal_error(call_id, reason, state)
    end
  end

  # No worker owns this row (a boot scan or a terminal write failed): it is
  # settled here by what it proves.
  defp stop_untracked(%{status: status} = row, why, state) do
    reply = if status == "admitted", do: :cancelled, else: :stopping
    {{:ok, reply}, settle(row, stop_reason(why), state)}
  end

  defp notify_worker(call_id, why, state) do
    %{pid: pid} = Map.fetch!(state.calls, call_id)

    case state.call_module.cancel(pid, why) do
      :ok -> :ok
      other -> Logger.error("phone call #{call_id} worker refused its stop: #{inspect(other)}")
    end
  end

  defp stop_reason(:owner), do: "cancelled_by_owner"
  defp stop_reason(:disabled), do: "phone_calls_disabled"

  defp disable_calls(state) do
    case Ledger.unsettled(server: state.repo) do
      {:ok, rows} -> Enum.reduce(rows, {%{cancelled: 0, stopping: 0}, state}, &disable_row/2)
      {:error, reason} -> disable_scan_failed(reason, state)
    end
  end

  defp disable_row(row, {counts, state}) do
    case cancel_row(row, :disabled, state) do
      {{:ok, :cancelled}, state} -> {Map.update!(counts, :cancelled, &(&1 + 1)), state}
      {{:ok, :stopping}, state} -> {Map.update!(counts, :stopping, &(&1 + 1)), state}
      {{:error, :already_terminal}, state} -> {counts, state}
      {{:error, reason}, state} -> {counts, log_terminal_error(row.id, reason, state)}
    end
  end

  # Admission is already closed; the tracked calls are still asked to stop, so
  # no live call outlives the switch for want of a ledger read.
  defp disable_scan_failed(reason, state) do
    Logger.error("phone calls disabled, but the ledger scan failed: #{inspect(reason)}")
    Enum.each(state.calls, fn {call_id, _call} -> notify_worker(call_id, :disabled, state) end)
    {%{cancelled: 0, stopping: map_size(state.calls)}, state}
  end

  # --- reconciliation and retention ---------------------------------------------

  defp reconcile(state) do
    case Ledger.unsettled(server: state.repo) do
      {:ok, rows} -> Enum.reduce(rows, state, &settle(&1, "engine_restarted", &2))
      {:error, reason} -> log_scan_error(reason, state)
    end
  end

  defp log_scan_error(reason, state) do
    Logger.warning("phone call boot reconciliation scan failed: #{inspect(reason)}")
    state
  end

  defp prune(state) do
    case Ledger.prune(now(state), server: state.repo) do
      {:ok, _counts} -> state
      {:error, reason} -> log_prune_error(reason, state)
    end
  end

  defp log_prune_error(reason, state) do
    Logger.warning("phone call retention prune failed: #{inspect(reason)}")
    state
  end

  defp arm_prune(%{timer_enabled?: false} = state), do: state

  defp arm_prune(state) do
    Process.send_after(self(), :phone_call_prune, state.prune_interval_ms)
    state
  end

  # --- state ------------------------------------------------------------------------

  defp build_state(opts) do
    %{
      call_module: Keyword.fetch!(opts, :call_module),
      hangup: fetch_hangup!(opts),
      repo: Keyword.get(opts, :repo, Repo),
      call_supervisor: Keyword.get(opts, :call_supervisor, FermixCore.PhoneCalls.CallSupervisor),
      handoff_supervisor:
        Keyword.get(opts, :handoff_supervisor, FermixCore.PhoneCalls.HandoffSupervisor),
      readiness: Keyword.get(opts, :readiness, &Readiness.current/0),
      config: Keyword.get(opts, :config, &Config.get/0),
      now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      continuation_opts: [dispatcher: Keyword.get(opts, :continuation_dispatcher)],
      reconcile?: Keyword.get(opts, :reconcile, true),
      timer_enabled?: Keyword.get(opts, :timer_enabled, true),
      prune_interval_ms: Keyword.get(opts, :prune_interval_ms, @default_prune_interval_ms),
      admission: :open,
      calls: %{},
      monitors: %{},
      cleanups: %{}
    }
  end

  defp fetch_hangup!(opts) do
    case Keyword.fetch!(opts, :hangup) do
      fun when is_function(fun, 1) ->
        fun

      other ->
        raise ArgumentError,
              "the :hangup option must be a 1-arity function, got: #{inspect(other)}"
    end
  end

  defp untrack(state, call_id) do
    case Map.pop(state.calls, call_id) do
      {nil, _calls} -> state
      {%{ref: ref}, calls} -> untracked(state, ref, calls)
    end
  end

  defp untracked(state, ref, calls) do
    Process.demonitor(ref, [:flush])
    %{state | calls: calls, monitors: Map.delete(state.monitors, ref)}
  end

  defp lease_end(state), do: DateTime.add(now(state), @handoff_lease_ms, :millisecond)
  defp now(state), do: state.now_fn.()

  defp text?(value), do: is_binary(value) and value != ""
end
