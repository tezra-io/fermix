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
      leasing the report to the hand-off (`Limits.handoff_lease_ms/0`), emits the
      closer, and runs the hand-off (`PhoneCalls.Delivery.hand_off/2`) in a
      task of `PhoneCalls.HandoffSupervisor`.
    * **A lost worker** (its DOWN arrives with no end report) and **boot
      reconciliation** (every non-terminal row, in `handle_continue`) are
      settled by what the row proves (`settle/3`): never dispatched → `failed`,
      nothing dialed; a closure the provider confirmed
      (`Ledger.record_closure/3`) → `ended` at that closure, its voice time as
      recorded, its outcome `unknown` with a note that what was said was never
      read (for a refused end report: could not be stored), no hang-up, the
      slot free; dispatch claimed with no session id → `dispatch_unknown`; a
      known provider session → `closure_unconfirmed`, and this process's
      cleanup request for that session through the injected `:hangup`,
      asynchronously, only when the row counts no hang-up request already,
      sent again only while it provably never left
      (`Limits.max_cleanup_retries/0`, each counted on the row first).
      Nothing is ever redialed, and supervision never restarts a worker.
    * **A ledger that does not answer.** Every `Ledger` call answers
      `{:error, :timeout}` instead of exiting. A terminal write the ledger
      refuses or does not answer keeps its report and is tried again on a
      timer, `Limits.max_terminal_write_attempts/0` in all, logged once when
      it starts failing and once when it lands; spent, the row is the next
      boot's. An admission it does not answer is refused as `:timeout`, and a
      row it committed late after all fails with nothing dialed. A count that
      pays for a side effect (the cleanup's) sends nothing unless written.
    * **Whether a call holds the slot** is published for turns to read
      without a call into this process (`slot_held?/2`): always the ledger's
      own answer, read at boot, at admission, at each terminal write and at
      the owner's release, never a row in hand.
    * **Cancel (`cancel/3`)** stops new work: a call not yet dispatched ends at
      once with nothing dialed (its later dispatch claim fails); a dispatched
      one is asked to stop and reads `stopping` until its end is known. A
      Manager that is not the home's daemon (`daemon: false`, a command that
      booted the tree) stops only a call it tracks itself, and answers
      `{:error, :owned_by_running_engine}` for any other, as it does for the
      owner's word that a call ended.
    * **The off switch (`disable/1`)**, serialized with admission here: no new
      start, admitted work that has not dispatched ends with nothing dialed,
      a live call is asked to stop. Cleanup, status, recovery and report
      delivery stay alive. `enable/1` reopens admission and nothing else: it
      releases no uncertain slot and redials nothing.
    * **The orderly stop's drain (`drain/1`)**, which `drain_for_stop/0`
      runs from the `prep_stop/1` of whichever application stops first, before
      any tree, the Repo or the network stack stops: admission closes for good, work not yet
      dispatched ends with nothing dialed, and a live call is asked to end
      (`cancel(pid, :shutdown)`, so it reports the engine's stop, not the
      owner's); the drain answers once every call has reported its end, or at
      `Limits.shutdown_drain_ms/0`. Nothing is forced at the bound: a call
      still running is left as the next boot's proof rules settle it, and a
      worker the tree's own shutdown then ends is not settled here. A crash
      or a kill is unchanged: boot reconciliation settles it.
    * **A home with durable memory off** has no ledger: the boot scans and
      prunes nothing and says so once. A prune that fails is logged once when
      it starts failing and once when it works again.

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
        parent_session: String.t(),     # the requesting turn's session (the row's parent_session)
        registry: atom()                # the subtree's call registry, to register in
      }

  merged over the `:call_args` option (a map, default empty): what the
  composition root hands every call's worker beside these, which the
  Manager passes through unread (`FermixCore.Application.phone_calls_opts/0`:
  the transport's wiring and the backend a call's turns run on).

  It must also export `cancel(pid, :owner | :disabled | :shutdown) :: :ok`, asynchronous
  (the Manager never waits on it), after which it stops new work, requests the
  hang-up of a known session, drains, and reports; and `prompt_version/0`, the
  version of its telephone instructions, snapshotted on the row at admission.

  It writes its own non-terminal steps through `PhoneCalls.Ledger` with
  `server: repo`, each guarded: `claim_dispatch/3` immediately before the one
  create request, which it sends only on `{:ok, _}` (a row cancelled or
  disabled first answers `{:error, {:not_admitted, status}}`);
  `record_session/4` as soon as the create returns a session id, before
  attaching; `advance/4` for ringing, answered and closing; `consume/3` before
  each backend turn, keypad key or cleanup attempt, acting only on `{:ok, _}`;
  `record_usage/4` for each cumulative usage snapshot; `record_closure/3` the
  moment the provider says the call closed (`session.closed`), before any
  result is read, so a restart cannot lose a verified end. Every one of them
  can answer `{:error, :timeout}` (the store did not answer within its
  bound): a write that pays for a side effect is then not made, so the side
  effect does not happen, and a timed-out write may still land later. It
  never writes a terminal row. It ends with exactly one `report_end/3`, whose report is

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
        vendor_message: String.t() | nil,
        uncertainty: String.t() | nil
      }

  (the outcome's four keys are `PhoneCalls.Outcome.to_report/1`'s; `uncertainty`
  is its own note on what stays uncertain, stored as `outcome_uncertainty`)
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
  alias FermixCore.PhoneCalls.Grants
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Prompt
  alias FermixCore.PhoneCalls.Readiness
  alias FermixCore.PhoneCalls.Report
  alias FermixCore.PhoneCalls.Telemetry

  @end_statuses ~w(ended failed dispatch_unknown closure_unconfirmed)
  # What the off switch did: calls it ended with nothing dialed, calls it asked
  # to stop, and calls it left to the home's running engine.
  @no_stops %{cancelled: 0, stopping: 0, running_engine: 0}
  @cleanup_resends Limits.max_cleanup_retries()
  # The uncertainty note of a call settled by its recorded closure.
  @closed_unread "The call ended, but what was said was never read, so the result is unknown."
  @closed_unstored "The call ended, but its result could not be stored, so it is unknown."
  @end_report_keys [
    :outcome,
    :outcome_facts,
    :evidence,
    :usage,
    :voice_seconds,
    :usage_state,
    :backend_usage,
    :failure_reason,
    :vendor_message,
    :uncertainty
  ]

  @type request :: %{
          required(:brief) => Brief.t(),
          required(:brief_hash) => String.t(),
          required(:request_id) => String.t(),
          required(:parent_session) => String.t(),
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
    GenServer.start_link(__MODULE__, [{:name, name} | opts], name: name)
  end

  @doc """
  Admits a call and starts its worker; answers its id and admission state.
  Refusals: `:disabled`, `{:needs_setup, reasons}`, `{:authorization_evidence,
  field}`, `{:tools_not_grantable, [{tool, why}]}` (`PhoneCalls.Grants`),
  `{:prompt_too_large, :instructions | :input, bytes}` (the brief would
  not reach the voice model whole), `{:slot_held, call_id}`,
  `{:daily_attempts_exhausted, n}`,
  `{:call_start_failed, reason}`, or the ledger's own error. The same request
  again answers its existing call with `reused: true`.
  """
  @spec start_call(request(), GenServer.server()) :: {:ok, started()} | {:error, term()}
  def start_call(request, server \\ __MODULE__) when is_map(request) do
    GenServer.call(server, {:start_call, request}, Limits.manager_reply_wait_ms())
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
    GenServer.call(server, {:cancel, call_id, owner_id}, Limits.manager_reply_wait_ms())
  end

  @doc "The off switch (see the moduledoc). Answers how many calls it ended and asked to stop."
  @spec disable(GenServer.server()) :: %{
          cancelled: non_neg_integer(),
          stopping: non_neg_integer()
        }
  def disable(server \\ __MODULE__),
    do: GenServer.call(server, :disable, Limits.manager_reply_wait_ms())

  @doc """
  Reopens admission. Releases no slot and redials nothing, and reopens
  nothing once the engine's stop has drained (`drain/1`).
  """
  @spec enable(GenServer.server()) :: :ok
  def enable(server \\ __MODULE__), do: GenServer.call(server, :enable)

  @doc """
  The owner's word that their unresolved call ended, which they checked in
  their Telnyx portal (`Management.PhoneCalls.confirm_ended/2`, M94 §12): the
  slot is released with the reason `owner_confirmed` at `now`
  (`Ledger.release_slot/4`), the outcome already recorded is unchanged, and the published
  slot fact (`slot_held?/2`) is read again, so admission and the `phone_call`
  tool see the slot free. Only the owner's own call whose termination is
  unconfirmed and that still holds the slot: `:not_found` for another
  owner's, `:in_progress` for one not yet over, `{:not_releasable, status}`
  for one already over, released, or past OpenAI's own limit.
  """
  @spec confirm_ended(String.t(), String.t(), DateTime.t(), GenServer.server()) ::
          {:ok, map()}
          | {:error, :not_found | :in_progress | {:not_releasable, String.t()} | term()}
  def confirm_ended(call_id, owner_id, %DateTime{} = now, server \\ __MODULE__)
      when is_binary(call_id) and is_binary(owner_id) do
    GenServer.call(
      server,
      {:confirm_ended, call_id, owner_id, now},
      Limits.manager_reply_wait_ms()
    )
  end

  @doc """
  The orderly stop's drain (see the moduledoc), run in the caller's process,
  never in the Manager's: `:idle` when no call is in progress (or no Manager
  runs), at once; `:drained` once every call has reported its end;
  `{:timeout, call_ids}` when `Limits.shutdown_drain_ms/0` passed first, the
  rows left for the next boot; `:already_drained` at once when an earlier
  drain of this engine's stop already ran; `{:no_answer, reason}` when the
  Manager died or gave no answer within the bound and a margin.
  """
  @spec drain(GenServer.server()) ::
          :idle
          | :drained
          | :already_drained
          | {:timeout, [String.t()]}
          | {:no_answer, term()}
  def drain(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :idle
      pid when is_pid(pid) -> await_drain(pid)
    end
  end

  @doc """
  The engine's orderly stop's drain, as every application that can stop
  first calls it from its own `prep_stop/1` (the web application, the
  channels application and the core). Applications stop in reverse start
  order and each starts after the ones it needs, so whichever of them stops
  first runs the drain while every application's tree, the call's backend
  among them, still runs; the later calls answer `:already_drained` at once.
  It drains the Manager `config :fermix_core, :phone_calls_stop_manager`
  names (a test's seam; this module otherwise), and says what it found once.
  """
  @spec drain_for_stop() ::
          :idle
          | :drained
          | :already_drained
          | {:timeout, [String.t()]}
          | {:no_answer, term()}
  def drain_for_stop do
    :fermix_core
    |> Application.get_env(:phone_calls_stop_manager, __MODULE__)
    |> drain()
    |> tap(&log_stop_drain/1)
  end

  defp log_stop_drain(result) when result in [:idle, :already_drained], do: :ok

  defp log_stop_drain(:drained),
    do: Logger.info("engine stop: the phone call in progress ended before the stop")

  defp log_stop_drain(other),
    do: Logger.warning("engine stop: phone calls not drained (#{inspect(other)})")

  defp await_drain(pid) do
    ref = Process.monitor(pid)
    send(pid, {:phone_call_drain, self(), ref})

    receive do
      {:phone_call_drained, ^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:no_answer, reason}
    after
      Limits.shutdown_drain_ms() + Limits.drain_reply_margin_ms() ->
        Process.demonitor(ref, [:flush])
        {:no_answer, :timeout}
    end
  end

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

  @doc """
  Whether a call holds the one-call slot at `now`, as the Manager registered
  as `server` last saw it: a call not yet terminal, or an uncertain one until
  its slot expires. What the `phone_call` tool offers status and stop by
  while phone calls are off. Read without a call into the Manager, so a turn
  may ask every time; `false` until that Manager has read its ledger once.
  """
  @spec slot_held?(DateTime.t(), GenServer.server()) :: boolean()
  def slot_held?(%DateTime{} = now, server \\ __MODULE__) do
    case :persistent_term.get(slot_key(server), :free) do
      :free -> false
      :held -> true
      until_ms when is_integer(until_ms) -> DateTime.to_unix(now, :millisecond) < until_ms
    end
  end

  # --- GenServer --------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, build_state(opts), {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, %{reconcile?: false} = state),
    do: {:noreply, state |> with_store() |> refresh_slot_fact()}

  def handle_continue(:reconcile, state) do
    {:noreply, state |> with_store() |> boot()}
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
    {reply, state} = disable_calls(admit_as(state, :closed))
    {:reply, reply, state}
  end

  def handle_call(:enable, _from, state), do: {:reply, :ok, admit_as(state, :open)}

  def handle_call({:confirm_ended, call_id, owner_id, now}, _from, state) do
    reply = release_on_owners_word(call_id, owner_id, now, state)
    {:reply, reply, refresh_slot_fact(state)}
  end

  @impl true
  def handle_info({:phone_call_ended, call_id, report}, state) do
    {:noreply, ended(call_id, report, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, down(ref, reason, state)}
  end

  def handle_info({:phone_call_drain, from, ref}, state)
      when is_pid(from) and is_reference(ref) do
    {:noreply, begin_drain({from, ref}, state)}
  end

  def handle_info({:phone_call_drain_deadline, token}, state) do
    {:noreply, drain_expired(token, state)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    {:noreply, cleanup_result(ref, result, state)}
  end

  def handle_info(:phone_call_prune, %{store?: false} = state), do: {:noreply, state}
  def handle_info(:phone_call_prune, state), do: {:noreply, state |> prune() |> arm_prune()}

  def handle_info({:phone_call_retry_cleanup, call_id, attempt}, state)
      when is_binary(call_id) and is_integer(attempt) do
    {:noreply, retry_cleanup(call_id, attempt, state)}
  end

  def handle_info({:phone_call_retry_write, call_id, op, attempt}, state)
      when is_binary(call_id) and is_integer(attempt) do
    {:noreply, write_terminal(state, call_id, op, attempt)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- admission ------------------------------------------------------------------

  defp admit(request, state) do
    with :ok <- admission_open(state),
         :ok <- ready(state),
         :ok <- check_evidence(request),
         :ok <- grants_allowed(request.brief),
         :ok <- prompt_fits(request.brief, state),
         {:ok, attrs} <- admission_attrs(request, state),
         {:ok, admission} <- admit_row(attrs, state) do
      start_admitted(admission, request.brief, state)
    else
      {:error, {:admission_unanswered, call_id}} ->
        {{:error, :timeout}, admission_unanswered(call_id, state)}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  # The admission goes out `skip_when_late` (`Ledger.admit/3`), so a Repo that
  # reaches it late turns it away unrun, yet one begun in time still commits.
  # Its id is this process's own, so the next message here fails that row with
  # nothing dialed if it exists: the Repo runs requests in order, so that
  # follow-up always comes after the admission, and an owner told the ledger
  # did not answer is never called after all.
  defp admit_row(attrs, state) do
    case Ledger.admit(attrs, now(state), server: state.repo) do
      {:error, :timeout} -> {:error, {:admission_unanswered, attrs.id}}
      answer -> answer
    end
  end

  defp admission_unanswered(call_id, state) do
    Logger.warning("phone call #{call_id} admission unanswered by the ledger; nothing was dialed")
    schedule_write(state, call_id, {:undispatched, "admission_unanswered"}, 1, 0)
  end

  # The one rule for a brief too large to send: the call's own prompt is
  # rendered as the worker will render it, and refused here, before any row
  # or attempt exists, when either part passes its bound. Sent whole or not at
  # all; the worker renders again at dispatch.
  defp prompt_fits(brief, state) do
    case Prompt.render(brief, now: now(state)) do
      {:ok, _rendered} -> :ok
      {:error, {:prompt_too_large, _part, _bytes} = reason} -> {:error, reason}
    end
  end

  defp admission_open(%{admission: :open}), do: :ok
  defp admission_open(%{admission: :closed}), do: {:error, :disabled}
  defp admission_open(%{admission: :stopping}), do: {:error, :engine_stopping}

  # The engine's stop closes admission for good: neither the off switch nor
  # the on switch moves it again.
  defp admit_as(%{admission: :stopping} = state, _admission), do: state
  defp admit_as(state, admission), do: %{state | admission: admission}

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
      parent_session: text?(Map.get(request, :parent_session)),
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

  # A brief grants only what a call's backend turn may use (`Grants`), so one
  # that asks for more is refused here, before any row or attempt exists.
  defp grants_allowed(%Brief{tool_grants: grants}) do
    with {:ok, _grantable} <- Grants.resolve(grants), do: :ok
  end

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
         id: Ledger.generate_id(),
         request_id: request.request_id,
         parent_session: request.parent_session,
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
        {{:ok, %{call_id: row.id, state: row.status, reused: false}},
         row |> track(pid, state) |> refresh_slot_fact()}

      {:error, reason} ->
        start_failed(row, reason, state)
    end
  end

  # Built here, not by the worker module, so a worker is `:temporary` whatever
  # it declares: supervision never restarts one, and so never replays a dial.
  defp child_spec(row, brief, state) do
    args =
      Map.merge(state.call_args, %{
        call_id: row.id,
        row: row,
        brief: brief,
        manager: self(),
        repo: state.repo,
        now_fn: state.now_fn,
        session_id: Telemetry.session_id(row.id),
        parent_session: row.parent_session,
        registry: state.call_registry
      })

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

  # Every terminal write, whichever path asks for it, is one `op`, tried by
  # `write_terminal/4`:
  #
  #   * `{:end_report, status, fields}`: a worker's end report (`report_end/3`);
  #   * `{:settle, reason}`: read the row and settle it by what it proves;
  #   * `{:settle_as, status, fields, hangup?}`: what that settle decided;
  #   * `{:undispatched, reason}`: work that never dispatched ends failed.
  #
  # A write the store refuses or does not answer is kept and tried again,
  # `Limits.max_terminal_write_attempts/0` in all, each wait doubling from
  # `Limits.terminal_write_retry_ms/0`, on a timer (`:write_schedule`), so this
  # process never waits between tries; logged once when it starts failing and
  # once when it lands. Spent, the row is left to the next boot's proof rules.
  # Once only throughout: a row already terminal answers `:already_terminal`.
  # A write that timed out still runs when the Repo reaches it, so a later
  # `:already_terminal` for that call is that write landing late: its closer
  # and hand-off run then, from the row.

  defp ended(call_id, report, state) do
    case Map.fetch(state.calls, call_id) do
      {:ok, _call} -> state |> untrack(call_id) |> write_end_report(call_id, report) |> drained?()
      :error -> log_untracked_end_report(call_id, state)
    end
  end

  defp log_untracked_end_report(call_id, state) do
    Logger.debug("phone call #{call_id} end report ignored: the call is not tracked")
    state
  end

  defp write_end_report(state, call_id, report) do
    case end_report_fields(report, state) do
      {:ok, status, fields} -> write_terminal(state, call_id, {:end_report, status, fields}, 1)
      {:error, reason} -> refused_end_report(call_id, reason, state)
    end
  end

  defp end_report_fields(%{status: status} = report, state) when status in @end_statuses do
    {:ok, status, report |> Map.take(@end_report_keys) |> Map.put(:ended_at, now(state))}
  end

  defp end_report_fields(report, _state),
    do: {:error, {:invalid, :status, Map.get(report, :status)}}

  defp settle_id(call_id, reason, state), do: write_terminal(state, call_id, {:settle, reason}, 1)

  defp fail_undispatched(call_id, reason, state),
    do: write_terminal(state, call_id, {:undispatched, reason}, 1)

  # A settle answers at most two more ops before a write (the undispatched
  # fail, then a settle of the row that moved past it), as a status only
  # moves forward, so this recursion ends.
  defp write_terminal(state, call_id, op, attempt) do
    case run_terminal(op, call_id, state) do
      {:ok, row} -> state |> write_landed(call_id, attempt) |> after_terminal(row, op)
      {:settled, next} -> write_terminal(state, call_id, next, attempt)
      :already_terminal -> already_terminal(state, call_id, op, attempt)
      :gone -> state |> clear_failure(call_id) |> log_gone(call_id)
      {:refused, reason} -> refused_end_report(call_id, reason, clear_failure(state, call_id))
      {:rejected, reason} -> state |> clear_failure(call_id) |> log_rejected(call_id, reason)
      {:error, reason} -> write_failed(state, call_id, op, attempt, reason)
    end
  end

  # A report the ledger refuses (`{:invalid, _, _}`) is settled by the row; a
  # settlement it refuses is logged, never settled again, so settling cannot
  # recurse.
  defp run_terminal({:end_report, status, fields}, call_id, state) do
    case terminal_answer(Ledger.terminalize(call_id, status, leased(fields, state), opts(state))) do
      {:rejected, reason} -> {:refused, reason}
      answer -> answer
    end
  end

  defp run_terminal({:settle, reason}, call_id, state) do
    case Ledger.get(call_id, opts(state)) do
      {:ok, row} -> settle(row, reason, state)
      other -> terminal_answer(other)
    end
  end

  defp run_terminal({:settle_as, status, fields, _hangup?}, call_id, state),
    do: terminal_answer(Ledger.terminalize(call_id, status, leased(fields, state), opts(state)))

  defp run_terminal({:undispatched, reason}, call_id, state) do
    opts = [server: state.repo, next_delivery_at: lease_end(state)]

    case Ledger.fail_undispatched(call_id, reason, now(state), opts) do
      {:error, {:dispatched, _status}} -> {:settled, {:settle, reason}}
      other -> terminal_answer(other)
    end
  end

  defp terminal_answer({:ok, row}), do: {:ok, row}
  defp terminal_answer({:error, :already_terminal}), do: :already_terminal
  defp terminal_answer({:error, :not_found}), do: :gone
  defp terminal_answer({:error, {:invalid, _key, _value} = reason}), do: {:rejected, reason}
  defp terminal_answer({:error, reason}), do: {:error, reason}

  # The hand-off lease runs from each attempt, so a retried write never lands
  # already due.
  defp leased(fields, state), do: Map.put(fields, :next_delivery_at, lease_end(state))

  defp opts(state), do: [server: state.repo]

  defp after_terminal(state, row, {:settle_as, _status, _fields, true}),
    do: row |> post_terminal(state) |> request_cleanup(row)

  defp after_terminal(state, row, _op), do: post_terminal(row, state)

  defp already_terminal(state, call_id, op, attempt) do
    case Map.get(state.write_failures, call_id) do
      :maybe_landed -> state |> write_landed(call_id, attempt) |> landed_late(call_id, op)
      _none -> clear_failure(state, call_id)
    end
  end

  defp landed_late(state, call_id, op) do
    case Ledger.get(call_id, opts(state)) do
      {:ok, row} -> after_terminal(state, row, op)
      {:error, reason} -> log_terminal_error(call_id, reason, state)
    end
  end

  defp write_failed(state, call_id, op, attempt, reason) do
    if attempt >= Limits.max_terminal_write_attempts() do
      Logger.error(
        "phone call #{call_id} terminal write not made after #{attempt} attempts " <>
          "(#{inspect(reason)}); its row is left for the next boot"
      )

      clear_failure(state, call_id)
    else
      wait = Limits.terminal_write_retry_ms() * Bitwise.bsl(1, attempt - 1)
      state |> note_failure(call_id, op, reason) |> schedule_write(call_id, op, attempt + 1, wait)
    end
  end

  defp note_failure(state, call_id, op, reason) do
    unless Map.has_key?(state.write_failures, call_id) do
      Logger.warning(
        "phone call #{call_id} terminal write failed (#{inspect(reason)}); trying again"
      )
    end

    kind = failure_kind(op, reason)
    failures = Map.update(state.write_failures, call_id, kind, &kept_kind(&1, kind))
    %{state | write_failures: failures}
  end

  # A write that timed out may still land; a read, or a write the store
  # answered with an error, did not. Once possibly landed, always so.
  defp failure_kind({:settle, _reason}, _error), do: :not_written
  defp failure_kind(_write, :timeout), do: :maybe_landed
  defp failure_kind(_write, _error), do: :not_written

  defp kept_kind(:maybe_landed, _kind), do: :maybe_landed
  defp kept_kind(_old, kind), do: kind

  defp schedule_write(state, call_id, op, attempt, wait) do
    _timer = state.write_schedule.({:phone_call_retry_write, call_id, op, attempt}, wait)
    state
  end

  defp write_landed(state, call_id, attempt) do
    if Map.has_key?(state.write_failures, call_id) do
      Logger.info("phone call #{call_id} terminal write landed on attempt #{attempt}")
    end

    clear_failure(state, call_id)
  end

  defp clear_failure(state, call_id),
    do: %{state | write_failures: Map.delete(state.write_failures, call_id)}

  defp log_gone(state, call_id) do
    Logger.info("phone call #{call_id} has no ledger row to settle")
    state
  end

  defp log_rejected(state, call_id, reason) do
    Logger.error(
      "phone call #{call_id} settlement refused by the ledger (#{inspect(reason)}); " <>
        "its row is left for the next boot"
    )

    state
  end

  defp refused_end_report(call_id, reason, state) do
    Logger.error(
      "phone call #{call_id} end report refused (#{inspect(reason)}); settling by its row"
    )

    settle_id(call_id, "invalid_end_report", state)
  end

  defp log_terminal_error(call_id, reason, state) do
    Logger.error("phone call #{call_id} ledger write failed: #{inspect(reason)}")
    state
  end

  # The closer, then the hand-off in a task of its own, so this process never
  # waits on a send. A task that cannot start leaves the report pending, and
  # the DeliveryWorker sends it once the lease ends. The call may have freed
  # the slot.
  defp post_terminal(row, state) do
    Telemetry.run_end(row)
    log_call_end(row)

    opts = [
      repo: state.repo,
      now_fn: state.now_fn,
      delivery_opts: state.delivery_opts,
      continuation_opts: state.continuation_opts
    ]

    case Task.Supervisor.start_child(state.handoff_supervisor, fn ->
           Delivery.hand_off(row, opts)
         end) do
      {:ok, _pid} -> refresh_slot_fact(state)
      {:error, reason} -> row |> log_handoff_unstarted(reason, state) |> refresh_slot_fact()
    end
  end

  # The one line the general log keeps of a call's end, from the row this
  # Manager just wrote: its id, status, outcome and, in the daemon's own code
  # words, why it stopped (`Report.reason_codes/1`, never the detail beside a
  # code), its voice seconds and backend turns. Never a name, a number, the
  # brief, anything said on the call, OpenAI's own words or a credential.
  defp log_call_end(row) do
    reason =
      case Report.reason_codes(Map.get(row, :failure_reason)) do
        [] -> "none"
        codes -> Enum.join(codes, ",")
      end

    Logger.info(
      "phone call #{row.id} ended: status=#{row.status} outcome=#{row.outcome} " <>
        "reason=#{reason} voice_seconds=#{Map.get(row, :voice_seconds) || "unknown"} " <>
        "backend_turns=#{Map.get(row, :core_turns) || 0}"
    )
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
        state = %{state | monitors: monitors, calls: Map.delete(state.calls, call_id)}
        state |> worker_gone(call_id, reason) |> drained?()
    end
  end

  # After a drain's bound, the tree's own shutdown ends what still runs: such a
  # row is the next boot's to settle, by what it proves then.
  defp worker_gone(%{stopping?: true} = state, call_id, reason) do
    Logger.warning(
      "phone call #{call_id} worker ended by the engine's stop (#{inspect(reason)}); " <>
        "its row is left for the next boot"
    )

    state
  end

  defp worker_gone(state, call_id, reason), do: lost_worker(call_id, reason, state)

  defp lost_worker(call_id, reason, state) do
    Logger.warning("phone call #{call_id} worker ended without its report: #{inspect(reason)}")
    settle_id(call_id, "worker_lost", state)
  end

  defp settle_row(row, reason, state) do
    case settle(row, reason, state) do
      {:settled, op} -> write_terminal(state, row.id, op, 1)
      :already_terminal -> state
    end
  end

  # The one settle rule, for a row no live worker owns: it decides, and
  # `write_terminal/4` writes. Never dispatched: nothing was dialed. A closure
  # the provider confirmed (`Ledger.record_closure/3`): the call ended, so it
  # ends `ended` at that closure, its voice time as recorded, its outcome
  # unknown, with no hang-up, and its slot free. Claimed with no session id:
  # whether the provider placed it is unknown, and it is never dialed again. A
  # known session: it may still be live, so its end is unconfirmed, and this
  # process sends its one hang-up only when the row counts none already
  # (`Limits.max_immediate_termination_requests/0`).
  defp settle(%{status: status} = row, reason, state) do
    cond do
      Ledger.terminal?(status) ->
        :already_terminal

      status == "admitted" ->
        {:settled, {:undispatched, reason}}

      match?(%DateTime{}, row.closed_at) ->
        {:settled, closed_end(row, reason)}

      is_nil(row.provider_session_id) ->
        {:settled, unknown_end("dispatch_unknown", reason, state)}

      true ->
        {:settled, unconfirmed_end(row, reason, state)}
    end
  end

  defp closed_end(row, reason) do
    fields = %{
      outcome: "unknown",
      uncertainty: closed_note(reason),
      usage_state: "incomplete",
      failure_reason: reason,
      ended_at: row.closed_at
    }

    {:settle_as, "ended", fields, false}
  end

  defp closed_note("invalid_end_report"), do: @closed_unstored
  defp closed_note(_reason), do: @closed_unread

  defp unknown_end(status, reason, state) do
    {:settle_as, status, %{outcome: "unknown", failure_reason: reason, ended_at: now(state)},
     false}
  end

  defp unconfirmed_end(row, reason, state) do
    {:settle_as, status, fields, false} = unknown_end("closure_unconfirmed", reason, state)
    {:settle_as, status, fields, row.cleanup_attempts == 0}
  end

  # One cleanup request for a known session, consumed on the row before the
  # request goes out, and run outside this process. A count the ledger refuses
  # or does not answer (its cap among them) sends nothing.
  defp request_cleanup(state, row), do: request_cleanup(state, row, 1)

  defp request_cleanup(state, %{id: call_id, provider_session_id: session_id}, attempt) do
    with {:ok, _row} <- Ledger.consume(call_id, :cleanup_attempts, server: state.repo),
         %Task{ref: ref} <-
           Task.Supervisor.async_nolink(state.handoff_supervisor, fn ->
             state.hangup.(session_id)
           end) do
      %{state | cleanups: Map.put(state.cleanups, ref, {call_id, attempt})}
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
      {entry, cleanups} -> record_cleanup(entry, result, ref, %{state | cleanups: cleanups})
    end
  end

  # A request that provably never left (`{:not_sent, _}`) is sent again, after
  # `Limits.cleanup_retry_ms/0` doubling, while `Limits.max_cleanup_retries/0`
  # allows; one the provider accepted, refused or may have seen never is.
  defp record_cleanup({call_id, attempt}, result, ref, state) do
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        Logger.info("phone call #{call_id} hang-up requested for its known session")
        state

      {:error, {:not_sent, _why} = reason} ->
        call_id |> record_cleanup_error(reason, state) |> resend_cleanup(call_id, attempt)

      {:error, reason} ->
        record_cleanup_error(call_id, reason, state)
    end
  end

  defp resend_cleanup(state, call_id, attempt) when attempt <= @cleanup_resends do
    wait = Limits.cleanup_retry_ms() * Bitwise.bsl(1, attempt - 1)
    _timer = state.write_schedule.({:phone_call_retry_cleanup, call_id, attempt + 1}, wait)
    state
  end

  defp resend_cleanup(state, call_id, attempt) do
    Logger.warning("phone call #{call_id} cleanup hang-up not sent after #{attempt} tries")
    state
  end

  # The resend reads the row again, so a call that ended meanwhile, or a count
  # at its cap, sends nothing.
  defp retry_cleanup(call_id, attempt, state) do
    case Ledger.get(call_id, opts(state)) do
      {:ok, %{provider_session_id: session} = row} when is_binary(session) ->
        request_cleanup(state, row, attempt)

      {:ok, _row} ->
        state

      {:error, reason} ->
        log_cleanup_unsent(call_id, reason, state)
    end
  end

  defp cleanup_down(ref, reason, state) do
    case Map.pop(state.cleanups, ref) do
      {nil, _cleanups} ->
        state

      {{call_id, _attempt}, cleanups} ->
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

  # A Manager that is not the home's running engine (a command that booted
  # the tree in a process of its own) tracks no worker of the daemon's, so it
  # settles nothing it does not track: the running engine owns that call.
  defp cancel_row(%{status: status} = row, why, state) do
    cond do
      Ledger.terminal?(status) -> {{:error, :already_terminal}, state}
      Map.has_key?(state.calls, row.id) -> stop_tracked(row, why, state)
      not state.daemon? -> {{:error, :owned_by_running_engine}, state}
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
      {:error, :timeout} -> {{:ok, :stopping}, stop_unanswered(row.id, state)}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp stop_tracked(row, why, state) do
    notify_worker(row.id, why, state)
    {{:ok, :stopping}, mark_stopping(row.id, state)}
  end

  # The worker was told. A fail that timed out still lands when the Repo
  # reaches it, so the worker's own end report or its exit finds the row
  # terminal and runs the closer and hand-off from it (`already_terminal/4`).
  defp stop_unanswered(call_id, state) do
    Logger.warning("phone call #{call_id} stop unanswered by the ledger; its worker was told")
    %{state | write_failures: Map.put(state.write_failures, call_id, :maybe_landed)}
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
    {{:ok, reply}, settle_row(row, stop_reason(why), state)}
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
  defp stop_reason(:shutdown), do: "engine_stopped"

  # --- the orderly stop's drain ---------------------------------------------------

  # The engine's stop drains once: a later request answers at once.
  defp begin_drain(waiter, %{stopping?: true} = state),
    do: answer_drain([waiter], :already_drained, state)

  defp begin_drain(waiter, state) do
    state = %{state | admission: :stopping}

    cond do
      map_size(state.calls) == 0 -> answer_drain([waiter], :idle, state)
      is_nil(state.drain) -> state |> stop_for_shutdown() |> arm_drain([waiter])
      true -> put_in(state.drain.waiters, [waiter | state.drain.waiters])
    end
  end

  # Every call this process tracks is told the engine is stopping, by what its
  # row says: undispatched work ends with nothing dialed, a live call is asked
  # to end. A row no worker owns is the next boot's, as after any stop.
  defp stop_for_shutdown(state) do
    Enum.reduce(Map.keys(state.calls), state, fn call_id, acc ->
      case Ledger.get(call_id, server: acc.repo) do
        {:ok, row} -> row |> cancel_row(:shutdown, acc) |> elem(1)
        {:error, reason} -> shutdown_unread(call_id, reason, acc)
      end
    end)
  end

  defp shutdown_unread(call_id, reason, state) do
    notify_worker(call_id, :shutdown, state)
    log_terminal_error(call_id, reason, state)
  end

  defp arm_drain(state, waiters) do
    token = make_ref()
    timer = state.drain_schedule.({:phone_call_drain_deadline, token}, Limits.shutdown_drain_ms())
    %{state | drain: %{waiters: waiters, token: token, timer: timer}}
  end

  # The drain's answer once every call has left this process's care.
  defp drained?(%{drain: %{} = drain, calls: calls} = state) when map_size(calls) == 0 do
    cancel_drain_timer(drain.timer)
    answer_drain(drain.waiters, :drained, %{state | drain: nil})
  end

  defp drained?(state), do: state

  defp drain_expired(token, %{drain: %{token: token} = drain} = state) do
    still = Map.keys(state.calls)

    Logger.warning(
      "phone calls still running when the engine's stop could wait no longer, left for " <>
        "the next boot: #{Enum.join(still, ", ")}"
    )

    answer_drain(drain.waiters, {:timeout, still}, %{state | drain: nil})
  end

  defp drain_expired(_stale, state), do: state

  defp answer_drain(waiters, result, state) do
    Enum.each(waiters, fn {pid, ref} -> send(pid, {:phone_call_drained, ref, result}) end)
    %{state | stopping?: true}
  end

  defp cancel_drain_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)

  defp disable_calls(state) do
    case Ledger.unsettled(server: state.repo) do
      {:ok, rows} -> Enum.reduce(rows, {@no_stops, state}, &disable_row/2)
      {:error, reason} -> disable_scan_failed(reason, state)
    end
  end

  defp disable_row(row, {counts, state}) do
    case cancel_row(row, :disabled, state) do
      {{:ok, :cancelled}, state} ->
        {Map.update!(counts, :cancelled, &(&1 + 1)), state}

      {{:ok, :stopping}, state} ->
        {Map.update!(counts, :stopping, &(&1 + 1)), state}

      {{:error, :already_terminal}, state} ->
        {counts, state}

      {{:error, :owned_by_running_engine}, state} ->
        {Map.update!(counts, :running_engine, &(&1 + 1)), state}

      {{:error, reason}, state} ->
        {counts, log_terminal_error(row.id, reason, state)}
    end
  end

  # Admission is already closed; the tracked calls are still asked to stop, so
  # no live call outlives the switch for want of a ledger read.
  defp disable_scan_failed(reason, state) do
    Logger.error("phone calls disabled, but the ledger scan failed: #{inspect(reason)}")
    Enum.each(state.calls, fn {call_id, _call} -> notify_worker(call_id, :disabled, state) end)
    {%{@no_stops | stopping: map_size(state.calls)}, state}
  end

  # --- reconciliation and retention ---------------------------------------------

  defp reconcile(state) do
    case Ledger.unsettled(server: state.repo) do
      {:ok, rows} -> Enum.reduce(rows, state, &settle_row(&1, "engine_restarted", &2))
      {:error, reason} -> log_scan_error(reason, state)
    end
  end

  defp log_scan_error(reason, state) do
    Logger.warning("phone call boot reconciliation scan failed: #{inspect(reason)}")
    state
  end

  # Whether this home keeps a ledger at all, decided once: the Repo's own
  # answer, which holds for the life of this subtree (a Repo restart restarts
  # it too). A Repo that does not answer is `:unanswered`, as any ledger call
  # that does not answer: the boot's reconciliation and prune are left to
  # the next boot, and the slot reads as held.
  defp with_store(state) do
    case Repo.enabled?(server: state.repo, on_timeout: :error) do
      enabled when is_boolean(enabled) -> %{state | store?: enabled}
      {:error, :repo_timeout} -> %{state | store?: :unanswered}
    end
  end

  defp boot(%{store?: :unanswered} = state) do
    Logger.warning(
      "phone calls: the store did not say whether it keeps a ledger; boot reconciliation " <>
        "is left for the next boot"
    )

    state |> refresh_slot_fact() |> arm_prune()
  end

  defp boot(%{store?: false} = state) do
    Logger.info("phone calls: durable memory is off, so there is no call ledger to reconcile")
    refresh_slot_fact(state)
  end

  defp boot(state), do: state |> reconcile() |> refresh_slot_fact() |> prune() |> arm_prune()

  defp prune(state) do
    case Ledger.prune(now(state), server: state.repo) do
      {:ok, _counts} -> prune_works(state)
      {:error, reason} -> prune_failed(reason, state)
    end
  end

  # Logged once when it starts failing and once when it works again.
  defp prune_failed(reason, %{prune_failures: 0} = state) do
    Logger.warning("phone call retention prune failed: #{inspect(reason)}")
    %{state | prune_failures: 1}
  end

  defp prune_failed(_reason, state), do: %{state | prune_failures: state.prune_failures + 1}

  defp prune_works(%{prune_failures: 0} = state), do: state

  defp prune_works(state) do
    Logger.info(
      "phone call retention prune works again after #{state.prune_failures} failed prunes"
    )

    %{state | prune_failures: 0}
  end

  defp arm_prune(%{timer_enabled?: false} = state), do: state

  defp arm_prune(state) do
    Process.send_after(self(), :phone_call_prune, state.prune_interval_ms)
    state
  end

  # --- the owner's word that a call ended -------------------------------------------

  defp release_on_owners_word(_call_id, _owner_id, _now, %{daemon?: false}),
    do: {:error, :owned_by_running_engine}

  defp release_on_owners_word(call_id, owner_id, now, state) do
    with {:ok, row} <- Ledger.get_for_owner(call_id, owner_id, opts(state)),
         :ok <- confirmable(row, now) do
      Ledger.release_slot(call_id, :owner_confirmed, now, opts(state))
    end
  end

  defp confirmable(row, now) do
    cond do
      not Ledger.terminal?(row.status) -> {:error, :in_progress}
      Ledger.holds_slot?(row, now) -> :ok
      true -> {:error, {:not_releasable, row.status}}
    end
  end

  # --- whether a call holds the slot -------------------------------------------------

  # Published where a turn reads it without a call here (`slot_held?/2`), by
  # one function (`refresh_slot_fact/1`): the ledger's own answer to which
  # rows hold the slot (`Ledger.outstanding/2`), read at boot, at admission,
  # at each terminal write and at the owner's release, never a row in hand,
  # so a write that lands late for one call cannot free the slot another
  # holds. As
  # `:free`, `:held` (a call not yet terminal) or the unix millisecond an
  # uncertain call's slot expires: immediates, so publishing one triggers no
  # global garbage collection. A ledger that does not answer publishes
  # `:held`: status and stop stay offered, never start.
  defp refresh_slot_fact(%{store?: false} = state), do: publish_slot(state, :free)
  defp refresh_slot_fact(%{store?: :unanswered} = state), do: publish_slot(state, :held)

  defp refresh_slot_fact(state) do
    case Ledger.outstanding(now(state), opts(state)) do
      {:ok, rows} -> publish_rows(state, rows)
      {:error, reason} -> slot_unread(reason, state)
    end
  end

  defp publish_rows(state, rows) do
    now = now(state)

    rows
    |> Enum.filter(&Ledger.holds_slot?(&1, now))
    |> Enum.reduce(:free, &wider(row_fact(&1), &2))
    |> then(&publish_slot(state, &1))
  end

  defp row_fact(%{status: status, slot_expires_at: %DateTime{} = expires}) do
    if Ledger.terminal?(status), do: DateTime.to_unix(expires, :millisecond), else: :held
  end

  defp row_fact(_row), do: :held

  defp wider(:held, _fact), do: :held
  defp wider(_fact, :held), do: :held
  defp wider(fact, :free), do: fact
  defp wider(one, other), do: max(one, other)

  defp slot_unread(reason, state) do
    Logger.warning(
      "phone calls: the ledger did not say whether a call holds the slot: #{inspect(reason)}"
    )

    publish_slot(state, :held)
  end

  defp publish_slot(state, fact) do
    :ok = :persistent_term.put(slot_key(state.name), fact)
    state
  end

  defp slot_key(server), do: {__MODULE__, :slot, server}

  # --- state ------------------------------------------------------------------------

  defp build_state(opts) do
    %{
      name: Keyword.get(opts, :name, __MODULE__),
      call_module: Keyword.fetch!(opts, :call_module),
      hangup: fetch_hangup!(opts),
      repo: Keyword.get(opts, :repo, Repo),
      call_supervisor: Keyword.get(opts, :call_supervisor, FermixCore.PhoneCalls.CallSupervisor),
      call_registry: Keyword.get(opts, :call_registry, FermixCore.PhoneCalls.CallRegistry),
      call_args: Keyword.get(opts, :call_args, %{}),
      handoff_supervisor:
        Keyword.get(opts, :handoff_supervisor, FermixCore.PhoneCalls.HandoffSupervisor),
      readiness: Keyword.get(opts, :readiness, &Readiness.current/0),
      config: Keyword.get(opts, :config, &Config.get/0),
      now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      continuation_opts: [dispatcher: Keyword.get(opts, :continuation_dispatcher)],
      reconcile?: Keyword.get(opts, :reconcile, true),
      daemon?: Keyword.get(opts, :daemon, true),
      timer_enabled?: Keyword.get(opts, :timer_enabled, true),
      prune_interval_ms: Keyword.get(opts, :prune_interval_ms, Limits.prune_interval_ms()),
      drain_schedule: Keyword.get(opts, :drain_schedule, &schedule_self/2),
      write_schedule: Keyword.get(opts, :write_schedule, &schedule_self/2),
      write_failures: %{},
      admission: :open,
      store?: true,
      stopping?: false,
      drain: nil,
      prune_failures: 0,
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

  # Runs in this process, so the deadline comes back here.
  defp schedule_self(message, ms), do: Process.send_after(self(), message, ms)

  defp lease_end(state),
    do: DateTime.add(now(state), Limits.handoff_lease_ms(), :millisecond)

  defp now(state), do: state.now_fn.()

  defp text?(value), do: is_binary(value) and value != ""
end
