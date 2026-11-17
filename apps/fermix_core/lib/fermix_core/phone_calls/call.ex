defmodule FermixCore.PhoneCalls.Call do
  @moduledoc """
  The per-call worker (M94 §04, §08, §09, §10): the one process that dials a
  phone call, attaches to it, observes it, controls it and ends it, and then
  sends `PhoneCalls.Manager` the call's one end report. It meets the
  Manager's worker contract (`PhoneCalls.Manager`'s moduledoc): started
  `:temporary` with the Manager's args, `cancel/2` asynchronous,
  `prompt_version/0` the telephone instructions' version.

  This module is the process: thin callbacks over what the call does next.
  What is one concept of its own lives beside it, pure or nearly so:
  `Call.Delegations` (the backend turns' slots and handles), `Call.Keypad`
  (one key at a time), `Call.Ending` (what ends a call, the words each end
  writes, and its stages), `Call.EndReport` (the one report), `Call.Timers`
  and `Call.Tasks` (its timers and its linked tasks) and `Call.Printable`
  (what its status prints). The controls a backend turn uses reach it
  through `PhoneCalls.CallControls`. Every bound it enforces is
  `PhoneCalls.Limits`'.

  Its callbacks never wait: the create request (which can wait up to a minute
  for its answer), each hangup request, the outcome extraction and each stop
  of a backend turn (`Delegate.cancel/2`, which in production waits on the
  gateway queue) run in linked tasks whose results arrive as messages, and
  every timer is delivered as a message. So it answers a cancel, a keypad
  press or a finish at every moment, and nothing on its way to a hangup calls
  into another application. Its only blocking calls are the ledger's, each
  bounded (`{:error, :timeout}`), and the sideband's local frame sends.

  ## States

    * `dispatching` (its `handle_continue`): readiness is asked again
      (`PhoneCalls.Readiness`, the one decision admission and the settings
      status use), over the section read once for the dispatch and the
      backend this worker was handed; then the credentials are resolved, the
      prompt rendered, and `Ledger.claim_dispatch/3` written. Any refusal
      ends here as `failed` with nothing dialed, what is missing in
      Readiness's own words. On the claim, exactly ONE create request starts,
      in a task.
    * `creating`: the create is in flight. It cannot be retracted, so a
      cancel here is only remembered. Rejected or provably not sent →
      `failed`, in the vendor's words; its answer lost or no answer by
      `Limits.max_create_wait_ms/0` → `dispatch_unknown`. Nothing is ever
      sent again. A session id is recorded (`record_session/4`) before
      anything else; with a cancel remembered, the session is only closed
      (hung up), never attached.
    * `attaching`: the sideband is started at once, bounded by the
      transport's attach deadline. The row's persisted ringing and call
      deadlines are armed. A late or failed attach ends the call.
    * `live`: events are reduced forward only. Ringing is optional;
      `answered`, or the recipient's first words when `answered` was missed,
      make the call active (which never means a person answered), stop the
      ringing timer, start the recipient-silence timer and send the opening
      line once. Transcript fragments are kept in arrival order, in bounded
      memory (`Limits.max_transcript_bytes/0`), never logged. Delegations run
      one scoped backend turn each through the `PhoneCalls.Delegate` the
      start args name; the keypad and the finish request come from that turn.
    * `ending`, from any end (`Call.Ending`'s causes): backend work is
      stopped first; a reply still being spoken gets a bounded wait; the row
      advances to `closing`; `consume(:cleanup_attempts)`; ONE hangup request
      (none once `session.closed` came, and sent again only when it provably
      never left); then the sideband is kept for `Limits.terminal_drain_ms/0`
      to receive `session.closed`, which is written the moment it arrives
      (`Ledger.record_closure/3`), so a confirmed end survives the worker.
    * `finalizing`: the sideband is closed and the one outcome extraction
      runs, bounded by its own timeout and `Limits.result_extraction_grace_ms/0`
      more. Then the one end report goes to the Manager and the worker exits
      normally.

  The engine's stop (`cancel(pid, :shutdown)`) shortens every state, the
  ending tail included: no wait for speech, the stop's own hangup wait for a
  hangup still outstanding, no outcome read (one in flight is abandoned), and
  the report at once, saying the outcome was not read because Fermix
  stopped. An owner's stop or the off switch in the tail changes nothing.

  What is said on the call when a backend turn ends it (`finish`): its reply,
  when it has one (`:done` a goodbye, `:needs_owner` that the owner will
  follow up, `:cannot_proceed` whatever it closes with). A turn that fails to
  answer leaves nothing on the line after `:done` or `:cannot_proceed` (the
  conversation is over), and the one sentence a person should hear after
  `:needs_owner`. On `:voicemail` nothing at all is said: no reply, no line
  and no wait; the call is hung up at once.

  ## Start args and seams

  The Manager's args (its worker contract), merged over what the composition
  root hands every worker (`FermixCore.Application.phone_calls_opts/0`):
  `:transport_opts` (the transport's wiring) and `:delegate` (the backend a
  call's turns run on; `nil` when none is configured, which Readiness
  refuses, so such a call dials nothing). The rest are production values
  unless a test names its own: `:transport` (`PhoneCalls.CallTransport`),
  `:readiness` (`&Readiness.current/1`, handed `:config` and
  `:call_backend?`), `:outcome` (`PhoneCalls.Outcome`),
  `:prompt` (`PhoneCalls.Prompt`), `:config` (`&PhoneCalls.Config.get/0`),
  `:credentials` (`credentials/1`), `:ledger` (`PhoneCalls.Ledger`),
  `:schedule` (`Process.send_after/3` to itself), `:monotonic`
  (milliseconds) and `:registry` (`CallControls.registry_name/0`).
  """

  use GenServer

  require Logger

  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Call.Delegations
  alias FermixCore.PhoneCalls.Call.Ending
  alias FermixCore.PhoneCalls.Call.EndReport
  alias FermixCore.PhoneCalls.Call.Keypad
  alias FermixCore.PhoneCalls.Call.Printable
  alias FermixCore.PhoneCalls.Call.Tasks
  alias FermixCore.PhoneCalls.Call.Timers
  alias FermixCore.PhoneCalls.CallControls
  alias FermixCore.PhoneCalls.CallTransport
  alias FermixCore.PhoneCalls.CarrierProfile
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Delegate
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Manager
  alias FermixCore.PhoneCalls.Outcome
  alias FermixCore.PhoneCalls.Prompt
  alias FermixCore.PhoneCalls.Readiness

  # A turn's handle: random bytes, never a bound.
  @handle_bytes 18

  # What the voice is given to say when a backend turn cannot answer. Each is
  # a sentence the person called may hear: never the engine's own words.
  @busy_line "Please bear with me; I am still on your earlier request."
  @turns_spent_line "I can't look into anything more during this call; the owner will " <>
                      "follow up. Thank you for your time."
  @failed_line "I can't get that done during this call; the owner will follow up on it."
  @timeout_line "That is taking too long; the owner will follow up on it."
  @owner_follows_up "The owner will follow up with you about this."
  @transcript_full "The call's transcript reached its size limit, so its result was not read."
  @extraction_failed "Fermix could not read the call's result."
  @engine_stopped "Fermix stopped during the call, so its result was not read."

  # Inspected anywhere (a crash's stack frame, which carries its arguments
  # past `format_status/1`; `:sys.get_state/1`), the state prints only these
  # fields: never the call's words, a handle or a seam.
  @derive {Inspect,
           only: [
             :call_id,
             :session_id,
             :phase,
             :dispatch,
             :provider_session,
             :progress,
             :answered?,
             :attached?,
             :transcript_bytes,
             :transcript_full?,
             :usage_seconds,
             :engine_stop?,
             :cancel,
             :ending
           ]}
  defstruct [
    :call_id,
    :row,
    :brief,
    :manager,
    :repo,
    :now_fn,
    :session_id,
    :parent_session,
    :registry,
    :transport,
    :transport_opts,
    :delegate,
    :readiness,
    :ledger,
    :outcome,
    :prompt,
    :config,
    :credentials,
    :monotonic,
    :timers,
    :tasks,
    phase: :dispatching,
    dispatch: :none,
    provider_session: nil,
    sideband: nil,
    attached?: false,
    progress: :none,
    answered?: false,
    opening: nil,
    opening_sent?: false,
    transcript: [],
    transcript_bytes: 0,
    transcript_full?: false,
    last_assistant_ms: nil,
    usage_seconds: nil,
    closed: nil,
    call_failed: nil,
    vendor_error: nil,
    hangup_error: nil,
    hangup_started_ms: nil,
    delegations: Delegations.new(),
    backend: %{totals: %{}, turns: 0, unmeasured: 0},
    ledger_logged: MapSet.new(),
    keypad: nil,
    finish: nil,
    cancel: nil,
    engine_stop?: false,
    ending: nil
  ]

  # --- public API ---------------------------------------------------------------

  @doc "Starts the worker with its start args (see the moduledoc)."
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{call_id: call_id} = args) when is_binary(call_id),
    do: GenServer.start_link(__MODULE__, args)

  @doc """
  The Manager's stop: `:owner`, `:disabled`, or `:shutdown` (the engine's
  orderly stop, `PhoneCalls.Manager.drain/1`). Asynchronous. Before the
  dispatch claim nothing is dialed; a create in flight is waited for and its
  session, if any, only closed; a live call stops its backend work and ends.
  The engine's stop hangs up at once, with no wait for a reply still being
  spoken, waits for its hangup only `Limits.shutdown_hangup_wait_ms/0`, and
  reads no outcome, all to fit the engine's stop: the call reports that
  Fermix stopped (`engine_stopped`), outcome `unknown`.
  """
  @spec cancel(pid(), :owner | :disabled | :shutdown) :: :ok
  def cancel(pid, why) when is_pid(pid) and why in [:owner, :disabled, :shutdown],
    do: GenServer.cast(pid, {:cancel, why})

  @doc "The version of the telephone instructions a call runs on."
  @spec prompt_version() :: String.t()
  def prompt_version, do: Prompt.version()

  @doc """
  The credentials a call's I/O needs, resolved now: the OpenAI Platform key
  and the trunk connection's username and password, never kept. What is
  missing is named in `PhoneCalls.Readiness`'s words.
  """
  @spec credentials(Config.t()) ::
          {:ok, %{api_key: String.t(), sip_username: String.t(), sip_password: String.t()}}
          | {:error, :openai_api_key_missing | :sip_username_missing | :sip_password_missing}
  def credentials(%Config{} = config) do
    with {:ok, api_key} <- api_key(),
         {:ok, username} <- sip_username(config),
         {:ok, password} <- sip_password(config) do
      {:ok, %{api_key: api_key, sip_username: username, sip_password: password}}
    end
  end

  # --- GenServer ------------------------------------------------------------------

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    state = build_state(args)

    case Registry.register(state.registry, state.call_id, nil) do
      {:ok, _owner} -> {:ok, state, {:continue, :dispatch}}
      {:error, reason} -> {:stop, {:not_registered, reason}}
    end
  end

  @impl true
  def handle_continue(:dispatch, state), do: state |> dispatch() |> noreply()

  @impl true
  def handle_cast({:cancel, why}, state), do: state |> cancel_call(why) |> noreply()
  def handle_cast(_other, state), do: noreply(state)

  @impl true
  def handle_call({:press_keys, handle, keys}, from, state) do
    case press(state, from, handle, keys) do
      {:deferred, state} -> noreply(state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:finish, handle, reason, note}, _from, state) do
    case finish_request(state, handle, reason, note) do
      {:ok, %{phase: :reported} = state} -> {:stop, :normal, :ok, state}
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_request}, state}

  @doc """
  The worker's status as a crash report or `:sys.get_status/1` prints it
  (`Call.Printable`): the state and the message in hand without the call's
  words, and a crash reason's stack frames by arity.
  """
  @impl true
  def format_status(status) when is_map(status) do
    status
    |> Map.replace_lazy(:state, &Printable.state/1)
    |> Map.replace_lazy(:message, &Printable.message/1)
    |> Map.replace_lazy(:reason, &Printable.reason/1)
  end

  @impl true
  def handle_info({:phone_sideband, pid, payload}, %{sideband: pid} = state) when is_pid(pid),
    do: state |> sideband(payload) |> noreply()

  def handle_info({:phone_sideband, _stopped, _payload}, state), do: noreply(state)

  def handle_info({:phone_call_timer, kind, token}, state),
    do: state |> timer(kind, token) |> noreply()

  def handle_info({:phone_call_delegation, call_id, id, revision, result}, state),
    do: state |> delegation_result(call_id, id, revision, result) |> noreply()

  def handle_info({ref, result}, state) when is_reference(ref),
    do: state |> task_message(ref, {:result, result}) |> noreply()

  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: state |> task_message(ref, {:down, reason}) |> noreply()

  def handle_info({:EXIT, pid, reason}, %{sideband: pid} = state) when is_pid(pid),
    do: state |> sideband_closed({:exited, describe(reason)}) |> noreply()

  def handle_info({:EXIT, _pid, _reason}, state), do: noreply(state)
  def handle_info(_other, state), do: noreply(state)

  defp noreply(%{phase: :reported} = state), do: {:stop, :normal, state}
  defp noreply(state), do: {:noreply, state}

  # --- dispatching ------------------------------------------------------------------

  defp dispatch(state) do
    config = state.config.()
    backend? = match?({:ok, _module}, Delegate.checked(state.delegate))

    with :ok <- ready(state.readiness.(config: config, call_backend?: backend?)),
         {:ok, creds} <- state.credentials.(config),
         {:ok, rendered} <- state.prompt.render(state.brief, now: now(state)),
         {:ok, row} <- state.ledger.claim_dispatch(state.call_id, now(state), server: state.repo) do
      start_create(
        %{state | row: row, opening: rendered.opening},
        create_request(state, creds, rendered)
      )
    else
      {:error, reason} -> report(state, :none, undispatched(reason))
    end
  end

  # The decision admission made, made again before anything is sent: a
  # setting changed since is caught here, in Readiness's own words.
  defp ready(:ready), do: :ok
  defp ready(:disabled), do: {:error, :phone_calls_disabled}
  defp ready({:needs_setup, [_ | _] = reasons}), do: {:error, {:needs_setup, reasons}}

  defp undispatched({:needs_setup, reasons}), do: Enum.map_join(reasons, "; ", &to_string/1)
  # The claim's store did not answer: whether it wrote is unknown, and nothing
  # was sent, so nothing was dialed.
  defp undispatched(:timeout), do: "dispatch_claim_timeout"
  defp undispatched(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp undispatched({:prompt_too_large, part, _bytes}), do: "prompt_too_large: #{part}"
  defp undispatched({:not_admitted, status}), do: "dispatch_claim_refused: #{status}"
  defp undispatched(reason), do: "dispatch_claim_failed: " <> describe(reason)

  defp create_request(state, creds, rendered) do
    %{
      api_key: creds.api_key,
      model: state.row.model,
      instructions: rendered.instructions,
      input: rendered.input,
      voice: state.row.voice,
      destination: state.brief.destination,
      trunk: %{
        provider_url: CarrierProfile.trunk_address(),
        username: creds.sip_username,
        password: creds.sip_password,
        caller_number: state.brief.caller_number
      }
    }
  end

  # The one create. The request, credentials included, lives only in the task.
  defp start_create(state, request) do
    %{transport: transport, transport_opts: opts} = state

    %{state | phase: :creating}
    |> start_task(:create, fn -> transport.create_session(request, opts) end)
    |> arm(:create_watchdog, Limits.max_create_wait_ms())
  end

  defp created(state, {:ok, %{session_id: session_id}}) when is_binary(session_id),
    do: session_created(state, session_id)

  defp created(state, {:error, {:rejected, status, vendor}}),
    do: report(state, :rejected, "create_rejected: HTTP #{status}", vendor_words(vendor))

  defp created(state, {:error, {:not_sent, reason}}),
    do: report(state, :not_sent, "create_not_sent: " <> describe(reason))

  defp created(state, {:error, {:unknown, reason}}),
    do: report(state, :unknown, "create_unknown: " <> describe(reason))

  defp created(state, other),
    do: report(state, :unknown, "create_unknown: " <> describe({:unexpected, other}))

  defp session_created(state, session_id) do
    state = %{state | dispatch: :created, provider_session: session_id, progress: :connecting}

    # A refusal and a store that did not answer alike: the session is hung up
    # by the id in hand and never attached.
    case state.ledger.record_session(state.call_id, session_id, now(state), server: state.repo) do
      {:ok, row} -> after_session(%{state | row: row})
      {:error, reason} -> session_not_recorded(state, reason)
    end
  end

  # A create that was cancelled in flight: its session is only closed.
  defp after_session(%{cancel: why} = state) when why in [:owner, :disabled, :shutdown],
    do: begin_end(%{state | engine_stop?: why == :shutdown}, {:cancelled, why})

  defp after_session(state), do: state |> arm_deadlines() |> attach()

  defp session_not_recorded(state, reason) do
    Logger.error("phone call #{state.call_id} session id not recorded: #{describe(reason)}")
    begin_end(state, :session_not_recorded)
  end

  defp attach(state) do
    # The sideband is handed both credentials and keeps only their scrub, so
    # every vendor word reaches this worker free of them.
    with {:ok, credentials} <- state.credentials.(state.config.()),
         {:ok, pid} <-
           state.transport.attach(state.provider_session, credentials, state.transport_opts) do
      %{state | phase: :attaching, sideband: pid}
      |> arm(:attach, state.transport.attach_deadline_ms())
    else
      {:error, reason} ->
        Logger.warning("phone call #{state.call_id} sideband not started: #{describe(reason)}")
        begin_end(state, :attach_failed)
    end
  end

  defp arm_deadlines(state) do
    state
    |> arm_at(:ringing, state.row.ringing_deadline_at)
    |> arm_at(:deadline, state.row.call_deadline_at)
  end

  # --- the sideband -------------------------------------------------------------------

  defp sideband(state, :attached), do: %{disarm(state, :attach) | phase: :live, attached?: true}

  defp sideband(state, {:attach_failed, reason}) do
    Logger.warning("phone call #{state.call_id} attach failed: #{describe(reason)}")
    begin_end(%{state | sideband: nil}, :attach_failed)
  end

  defp sideband(state, {:event, event}), do: event(event, state)

  defp sideband(state, {:invalid_frame, description}) do
    Logger.debug("phone call #{state.call_id} invalid sideband frame: #{describe(description)}")
    state
  end

  defp sideband(state, {:closed, reason}), do: sideband_closed(state, reason)

  defp sideband_closed(state, reason) do
    state = %{state | sideband: nil, attached?: false}

    case state.ending do
      nil -> lost_sideband(state, reason)
      %Ending{stage: :speech} -> state |> disarm(:speech) |> close_call()
      %Ending{stage: :draining} -> finalize(state)
      %Ending{} -> state
    end
  end

  defp lost_sideband(state, reason) do
    Logger.warning("phone call #{state.call_id} sideband lost: #{describe(reason)}")
    begin_end(state, :sideband_lost)
  end

  defp event({:ringing, _progress}, state), do: ringing(state)
  defp event({:answered, _progress}, state), do: answered(state)

  defp event({:call_failed, failure}, state),
    do: begin_end(%{state | call_failed: failure}, :call_failed)

  defp event({:transcript, fragment}, state), do: fragment(state, fragment)
  defp event({:delegation, delegation}, state), do: delegation(state, delegation)
  defp event({:usage, usage}, state), do: usage(state, usage)
  defp event({:session_closed, closed}, state), do: session_closed(state, closed)
  defp event({:dtmf_sent, _ack} = event, state), do: keypad_event(state, event)

  defp event({:vendor_error, error} = event, state),
    do: %{state | vendor_error: error.message || error.code} |> keypad_event(event)

  defp event(other, state) do
    Logger.debug("phone call #{state.call_id} event not acted on: #{event_kind(other)}")
    state
  end

  defp event_kind({kind, type, _event}) when kind in [:unknown, :malformed], do: "#{kind} #{type}"
  defp event_kind(other), do: other |> elem(0) |> to_string()

  defp ringing(%{progress: :connecting} = state),
    do: %{advance(state, "ringing") | progress: :ringing}

  defp ringing(state), do: state

  # Answered says the leg answered, never who: a person, a menu or a machine.
  defp answered(%{answered?: true} = state), do: state

  defp answered(state) do
    %{advance(state, "active") | answered?: true, progress: :active}
    |> disarm(:ringing)
    |> rearm_silence()
    |> send_opening()
  end

  defp send_opening(%{opening_sent?: false, ending: nil, attached?: true} = state),
    do: %{say(state, nil, state.opening) | opening_sent?: true}

  defp send_opening(state), do: state

  # Cumulative: each snapshot replaces the one before, never adds to it.
  defp usage(state, %{seconds: seconds, context_usage_ratio: ratio}) do
    snapshot = compact(%{"seconds" => seconds, "context_usage_ratio" => ratio})
    record_usage(%{state | usage_seconds: seconds}, snapshot, seconds)
  end

  # The confirmed end is written at once, before anything else is read, so a
  # worker lost from here on leaves a row the Manager settles as ended.
  defp session_closed(state, %{reason: reason, seconds: seconds}) do
    state = %{state | closed: %{reason: reason, seconds: seconds}} |> record_closure()

    case state.ending do
      nil -> begin_end(state, {:remote_closed, reason})
      %Ending{stage: :speech} -> state |> disarm(:speech) |> close_call()
      %Ending{} -> finalize(state)
    end
  end

  # --- the transcript ----------------------------------------------------------------

  defp fragment(%{transcript_full?: true} = state, _fragment), do: state

  defp fragment(state, %{speaker: speaker, text: text} = fragment) do
    if state.transcript_bytes + byte_size(text) > Limits.max_transcript_bytes() do
      begin_end(%{state | transcript_full?: true}, :transcript_limit)
    else
      entry = Map.take(fragment, [:speaker, :text, :start_ms, :end_ms])

      %{
        state
        | transcript: [entry | state.transcript],
          transcript_bytes: state.transcript_bytes + byte_size(text)
      }
      |> heard(speaker)
    end
  end

  # The recipient's words are evidence the leg is up even when `answered`
  # was missed before the attach.
  defp heard(state, :remote), do: state |> answered() |> rearm_silence()
  defp heard(state, :assistant), do: %{state | last_assistant_ms: state.monotonic.()}

  defp rearm_silence(%{ending: nil} = state),
    do: arm(state, :silence, Limits.recipient_silence_timeout_ms())

  defp rearm_silence(state), do: state

  # --- delegations ------------------------------------------------------------------

  defp delegation(%{ending: nil, finish: nil} = state, %{id: id, target: target})
       when target in [nil, "client"],
       do: take_delegation(state, id)

  defp delegation(state, _delegation), do: state

  defp take_delegation(state, id) do
    case Delegations.create(state.delegations, id) do
      {:active, record, delegations} -> consume_turn(%{state | delegations: delegations}, record)
      {:pending, _record, delegations} -> %{state | delegations: delegations}
      {:full, delegations} -> say(%{state | delegations: delegations}, id, @busy_line)
      {:duplicate, _delegations} -> state
    end
  end

  defp consume_turn(state, record) do
    case consume(state, :core_turns) do
      :ok ->
        arm(state, {:settle, record.id}, Limits.transcript_settle_ms())

      {:error, {:cap_reached, :core_turns}} ->
        state
        |> say(record.id, @turns_spent_line)
        |> retire(record.id)
        |> begin_end(:core_turn_limit)

      {:error, reason} ->
        Logger.warning(
          "phone call #{state.call_id} backend turn not counted: #{describe(reason)}"
        )

        state |> say(record.id, @failed_line) |> retire(record.id) |> next_delegation()
    end
  end

  # The window is cut after the settle wait: the late fragments are in.
  defp run_turn(state, id) do
    if Delegations.current?(state.delegations, id, Delegations.revision()) do
      handle = new_handle()
      started(state, id, handle, state.delegate.run(turn_request(state, id, handle)))
    else
      state
    end
  end

  defp started(state, id, handle, :ok) do
    {:ok, delegations} = Delegations.start(state.delegations, id, handle)
    arm(%{state | delegations: delegations}, {:turn_timeout, id}, Limits.core_turn_timeout_ms())
  end

  defp started(state, id, _handle, {:error, reason}) do
    Logger.warning("phone call #{state.call_id} backend turn not started: #{describe(reason)}")
    state |> say(id, @failed_line) |> retire(id) |> next_delegation()
  end

  defp turn_request(state, id, handle) do
    %{
      call_id: state.call_id,
      handle: handle,
      delegation_id: id,
      revision: Delegations.revision(),
      brief: state.brief,
      window: Enum.reverse(state.transcript),
      session_id: state.session_id,
      deadline_ms: Limits.core_turn_timeout_ms(),
      max_steps: Limits.max_agent_steps_per_core_turn(),
      reply_to: self()
    }
  end

  # A result acts only for this call, a current delegation and revision, and
  # a call not ending: a stale one cannot speak, press or reopen anything.
  defp delegation_result(%{call_id: call_id, ending: nil} = state, call_id, id, revision, result)
       when is_binary(id) and is_integer(revision) do
    case Delegations.finish(state.delegations, id, revision) do
      {:ok, _record, delegations} ->
        %{state | delegations: delegations}
        |> disarm({:turn_timeout, id})
        |> stop_turn_keys(id)
        |> answer_turn(id, result)
        |> after_turn()

      :stale ->
        Logger.debug("phone call #{state.call_id} stale backend answer ignored")
        state
    end
  end

  defp delegation_result(state, _call_id, _id, _revision, _result) do
    Logger.debug("phone call #{state.call_id} backend answer ignored: not current")
    state
  end

  # The reply is already checked and bounded (`PhoneCalls.Disclosure`, the one
  # owner of the append bound, which withholds a longer one).
  defp answer_turn(state, id, {:ok, %{reply: reply} = answer}) when is_binary(reply) do
    state
    |> add_backend(Map.get(answer, :backend_usage))
    |> say_reply(id, String.trim(reply))
  end

  defp answer_turn(state, id, {:error, reason}) do
    Logger.warning("phone call #{state.call_id} backend turn failed: #{describe(reason)}")
    state |> add_backend(nil) |> say_limitation(id, @failed_line)
  end

  defp answer_turn(state, id, _malformed) do
    Logger.error("phone call #{state.call_id} backend turn answered in an unknown shape")
    state |> add_backend(nil) |> say_limitation(id, @failed_line)
  end

  defp say_reply(state, id, ""), do: say_limitation(state, id, @failed_line)
  defp say_reply(state, id, reply), do: say(state, id, reply)

  # A turn that finished the call and could not answer: after `:done` or
  # `:cannot_proceed` the conversation is over and nothing is said; after
  # `:needs_owner` the person hears that the owner will follow up.
  defp say_limitation(%{finish: nil} = state, id, line), do: say(state, id, line)

  defp say_limitation(%{finish: %{reason: :needs_owner}} = state, id, _line),
    do: say(state, id, @owner_follows_up)

  defp say_limitation(state, _id, _line), do: state

  defp turn_timed_out(state, id) do
    case Delegations.finish(state.delegations, id, Delegations.revision()) do
      {:ok, record, delegations} ->
        %{state | delegations: delegations}
        |> cancel_turn(record)
        |> stop_turn_keys(id)
        |> add_backend(nil)
        |> say_limitation(id, @timeout_line)
        |> after_turn()

      :stale ->
        state
    end
  end

  defp after_turn(%{finish: %{reason: reason}} = state), do: begin_end(state, {:finish, reason})
  defp after_turn(state), do: next_delegation(state)

  defp next_delegation(%{ending: nil, finish: nil} = state) do
    case Delegations.promote(state.delegations) do
      {:ok, record, delegations} -> consume_turn(%{state | delegations: delegations}, record)
      :none -> state
    end
  end

  defp next_delegation(state), do: state

  defp retire(state, id) do
    case Delegations.finish(state.delegations, id, Delegations.revision()) do
      {:ok, _record, delegations} -> %{state | delegations: delegations}
      :stale -> state
    end
  end

  # Best effort and never waited on: the fencing is the authority. The stop
  # (in production a call into the gateway queue) runs in a task of the call's
  # own, which is stopped with the call if it is still running then.
  defp cancel_turn(state, %{id: id, handle: handle}) when is_binary(handle) do
    %{delegate: delegate, call_id: call_id} = state
    %{state | tasks: Tasks.start_stop(state.tasks, fn -> delegate.cancel(call_id, id) end)}
  end

  defp cancel_turn(state, _never_started), do: state

  # Backend usage across the call's turns, in the turn's own measure
  # (`Agents.PhoneCallTurn`: `"total_tokens"` and `"iterations"`): numbers
  # summed by key, and the turns that reported none counted apart, since
  # unknown is not zero. No turn reports a cost.
  defp add_backend(%{backend: backend} = state, usage) when is_map(usage) do
    totals =
      Enum.reduce(usage, backend.totals, fn
        {key, value}, acc when is_number(value) ->
          Map.update(acc, to_string(key), value, &(&1 + value))

        _other, acc ->
          acc
      end)

    %{state | backend: %{backend | totals: totals, turns: backend.turns + 1}}
  end

  defp add_backend(%{backend: backend} = state, nil),
    do: %{
      state
      | backend: %{backend | turns: backend.turns + 1, unmeasured: backend.unmeasured + 1}
    }

  defp backend_usage(%{backend: %{turns: 0}}), do: nil

  defp backend_usage(%{backend: backend}) do
    usage = Map.put(backend.totals, "turns", backend.turns)

    if backend.unmeasured == 0,
      do: usage,
      else: Map.put(usage, "turns_unmeasured", backend.unmeasured)
  end

  defp say(%{sideband: pid, attached?: true} = state, delegation_id, text)
       when is_pid(pid) and is_binary(text) do
    case state.transport.send_commentary(pid, delegation_id, text) do
      {:ok, _event_id} -> %{state | last_assistant_ms: state.monotonic.()}
      {:error, reason} -> log_unsaid(state, reason)
    end
  end

  defp say(state, _delegation_id, _text), do: state

  defp log_unsaid(state, reason) do
    Logger.warning("phone call #{state.call_id} could not reach the voice: #{describe(reason)}")
    state
  end

  # --- the keypad ----------------------------------------------------------------------

  defp press(state, from, handle, keys) do
    with {:ok, record} <- Delegations.check_handle(state.delegations, handle),
         :ok <- keypad_ready(state) do
      {:deferred, next_key(%{state | keypad: Keypad.new(from, record.id, keys)})}
    end
  end

  defp keypad_ready(%{keypad: %Keypad{}}), do: {:error, :keypad_busy}
  defp keypad_ready(%{phase: :live, ending: nil, attached?: true, answered?: true}), do: :ok
  defp keypad_ready(_state), do: {:error, :not_active}

  defp next_key(%{keypad: keypad} = state) do
    case Keypad.next(keypad) do
      {:press, key} -> count_key(state, key)
      :done -> keypad_done(state, nil)
    end
  end

  # Each key is counted before it goes out; a count that is refused or that
  # timed out sends nothing.
  defp count_key(state, key) do
    case consume(state, :dtmf_keys) do
      :ok ->
        send_key(state, key)

      {:error, {:cap_reached, :dtmf_keys} = cap} ->
        keypad_done(state, cap)

      {:error, reason} ->
        Logger.warning("phone call #{state.call_id} key not counted: #{describe(reason)}")
        keypad_done(state, :not_sent)
    end
  end

  defp send_key(state, key) do
    case state.transport.send_dtmf(state.sideband, key) do
      {:ok, event_id} ->
        %{state | keypad: Keypad.pressing(state.keypad, key, event_id)}
        |> arm(:dtmf_ack, Limits.dtmf_ack_timeout_ms())

      {:error, reason} ->
        keypad_done(state, Keypad.send_stopped(reason))
    end
  end

  defp keypad_event(%{keypad: %Keypad{} = keypad} = state, event) do
    case Keypad.acknowledge(keypad, event) do
      {:confirmed, keypad} -> %{disarm(state, :dtmf_ack) | keypad: keypad} |> next_key()
      :refused -> keypad_done(state, :refused)
      :unrelated -> state
    end
  end

  defp keypad_event(state, _event), do: state

  # A turn retired for any reason takes its key presses with it.
  defp stop_turn_keys(%{keypad: %Keypad{} = keypad} = state, id) do
    if Keypad.asked_by?(keypad, id), do: keypad_done(state, :turn_ended), else: state
  end

  defp stop_turn_keys(state, _id), do: state

  defp keypad_done(%{keypad: nil} = state, _stopped), do: state

  defp keypad_done(state, stopped) do
    {from, reply} = Keypad.answer(state.keypad, stopped)
    GenServer.reply(from, reply)
    %{disarm(state, :dtmf_ack) | keypad: nil}
  end

  # --- finish and cancel ------------------------------------------------------------------

  defp finish_request(state, handle, reason, note) do
    with {:ok, _record} <- Delegations.check_handle(state.delegations, handle),
         :ok <- finish_ready(state) do
      {:ok, finish_taken(%{state | finish: %{reason: reason, note: note}})}
    end
  end

  defp finish_ready(%{finish: %{}}), do: {:error, :already_finishing}
  defp finish_ready(%{phase: :live, ending: nil}), do: :ok
  defp finish_ready(_state), do: {:error, :not_active}

  # Voicemail: nothing is left on it, so the call ends now and the turn's
  # reply is never said. Any other finish ends once that turn has answered.
  defp finish_taken(%{finish: %{reason: :voicemail}} = state),
    do: begin_end(state, {:finish, :voicemail})

  defp finish_taken(state), do: state

  defp cancel_call(%{phase: phase} = state, why) when phase in [:dispatching, :creating],
    do: %{state | cancel: state.cancel || why}

  defp cancel_call(%{phase: phase} = state, :shutdown) when phase in [:attaching, :live],
    do: begin_end(%{state | engine_stop?: true}, {:cancelled, :shutdown})

  defp cancel_call(%{phase: phase} = state, why) when phase in [:attaching, :live],
    do: begin_end(state, {:cancelled, why})

  # In the ending tail only the engine's stop changes anything: it shortens
  # the tail to fit the stop's drain.
  defp cancel_call(%{phase: phase, engine_stop?: false} = state, :shutdown)
       when phase in [:ending, :finalizing],
       do: engine_stops(%{state | engine_stop?: true})

  defp cancel_call(state, _why), do: state

  defp engine_stops(%{phase: :finalizing} = state) do
    %{state | tasks: Tasks.shutdown(state.tasks, :extract)}
    |> disarm(:extract_watchdog)
    |> report_outcome(unread_outcome(@engine_stopped))
  end

  defp engine_stops(%{ending: %Ending{stage: :speech}} = state),
    do: state |> disarm(:speech) |> close_call()

  defp engine_stops(%{ending: %Ending{stage: :hangup}} = state) do
    if Tasks.running?(state.tasks, :hangup),
      do: arm(state, :hangup_watchdog, Limits.shutdown_hangup_wait_ms()),
      else: state |> disarm(:hangup_resend) |> drain_or_finalize()
  end

  # Draining: bounded by the drain, which the stop's own budget includes.
  defp engine_stops(state), do: state

  # --- ending ------------------------------------------------------------------------------

  defp begin_end(%{ending: %Ending{}} = state, _cause), do: state

  defp begin_end(state, cause) do
    %{state | phase: :ending, ending: Ending.new(cause)}
    |> disarm_all()
    |> stop_attaching()
    |> stop_backend_work()
    |> await_speech()
  end

  defp stop_attaching(%{attached?: false, sideband: pid} = state) when is_pid(pid) do
    state.transport.stop(pid)
    %{state | sideband: nil}
  end

  defp stop_attaching(state), do: state

  defp stop_backend_work(state) do
    {running, delegations} = Delegations.stop_all(state.delegations)
    state = Enum.reduce(running, %{state | delegations: delegations}, &cancel_turn(&2, &1))
    keypad_done(state, :call_ending)
  end

  defp await_speech(state) do
    if speaking?(state) and Ending.waits_for_speech?(state.ending, state.engine_stop?),
      do: state |> put_stage(:speech) |> arm(:speech, Limits.speech_quiet_ms()),
      else: close_call(state)
  end

  defp speech_check(state) do
    case Ending.speech_checked(state.ending, speaking?(state), state.engine_stop?) do
      {:wait, ending} -> arm(%{state | ending: ending}, :speech, Limits.speech_quiet_ms())
      :done -> close_call(state)
    end
  end

  defp speaking?(%{attached?: true, closed: nil, last_assistant_ms: said} = state)
       when is_integer(said),
       do: state.monotonic.() - said < Limits.speech_quiet_ms()

  defp speaking?(_state), do: false

  defp close_call(state) do
    state = advance(state, "closing")
    if state.closed, do: finalize(state), else: request_hangup(state)
  end

  defp request_hangup(state) do
    case consume(state, :cleanup_attempts) do
      :ok ->
        state |> put_stage(:hangup) |> start_hangup()

      {:error, reason} ->
        Logger.warning("phone call #{state.call_id} hangup not requested: #{describe(reason)}")
        after_hangup(state, {:error, {:not_sent, {:cleanup_not_counted, reason}}})
    end
  end

  defp start_hangup(state) do
    %{transport: transport, transport_opts: opts, credentials: credentials, config: config} =
      state

    session_id = state.provider_session

    %{state | hangup_started_ms: state.hangup_started_ms || state.monotonic.()}
    |> start_task(:hangup, fn ->
      hangup_once(transport, opts, credentials.(config.()), session_id)
    end)
    |> arm(:hangup_watchdog, hangup_wait_ms(state))
  end

  defp hangup_once(transport, opts, {:ok, %{api_key: api_key}}, session_id),
    do: transport.hangup(session_id, api_key, opts)

  defp hangup_once(_transport, _opts, {:error, reason}, _session_id),
    do: {:error, {:not_sent, reason}}

  # The engine's stop waits less for the hangup, so the call's end fits the
  # stop's drain (`Limits.shutdown_drain_ms/0`); unanswered, it is left as any
  # hangup whose watchdog fired.
  defp hangup_wait_ms(%{engine_stop?: true}), do: Limits.shutdown_hangup_wait_ms()
  defp hangup_wait_ms(_state), do: Limits.hangup_wait_ms()

  # The window a hangup that provably never left may be sent again in.
  defp hangup_window_ms(%{engine_stop?: true}), do: Limits.shutdown_hangup_wait_ms()
  defp hangup_window_ms(_state), do: Limits.cleanup_window_ms()

  # A request that provably never left is no repeat: it goes again, spaced,
  # inside the window, and the cleanup cap is consumed as it goes. An
  # accepted, refused or unknown one is never sent again.
  defp hangup_answered(state, {:error, {:not_sent, _reason}} = result) do
    if resend_in_window?(state),
      do: state |> hangup_noted(result) |> arm(:hangup_resend, Limits.hangup_resend_spacing_ms()),
      else: after_hangup(state, result)
  end

  defp hangup_answered(state, result), do: after_hangup(state, result)

  defp resend_in_window?(state) do
    elapsed = state.monotonic.() - state.hangup_started_ms
    elapsed + Limits.hangup_resend_spacing_ms() <= hangup_window_ms(state)
  end

  defp after_hangup(state, result), do: state |> hangup_noted(result) |> drain_or_finalize()

  defp drain_or_finalize(state) do
    if state.attached? and is_nil(state.closed),
      do: state |> put_stage(:draining) |> arm(:drain, Limits.terminal_drain_ms()),
      else: finalize(state)
  end

  defp hangup_noted(state, {:ok, :accepted}), do: state

  defp hangup_noted(state, {:ok, {:already_ended, status, _vendor}}) do
    Logger.info("phone call #{state.call_id} hangup: the provider had nothing to end (#{status})")
    state
  end

  defp hangup_noted(state, {:error, {:rejected, status, vendor}}),
    do: %{state | hangup_error: "rejected, HTTP #{status}: #{vendor_words(vendor) || "no words"}"}

  defp hangup_noted(state, {:error, reason}), do: %{state | hangup_error: describe(reason)}

  # The call's one outcome reading (M94 §10): `finalize/1` runs only in the
  # ending phase, which it leaves for good, and it is `extract/1`'s only
  # caller, so no call reads its outcome twice.
  defp finalize(%{phase: :ending} = state) do
    %{close_sideband(state) | tasks: Tasks.shutdown(state.tasks, :hangup)}
    |> disarm_all()
    |> Map.put(:phase, :finalizing)
    |> extract()
  end

  defp close_sideband(%{sideband: pid} = state) when is_pid(pid) do
    state.transport.close(pid)
    %{state | sideband: nil, attached?: false}
  end

  defp close_sideband(state), do: state

  defp put_stage(state, stage), do: %{state | ending: Ending.put_stage(state.ending, stage)}

  # --- finalizing ----------------------------------------------------------------------------

  defp extract(%{engine_stop?: true} = state),
    do: report_outcome(state, unread_outcome(@engine_stopped))

  defp extract(%{transcript_full?: true} = state),
    do: report_outcome(state, unread_outcome(@transcript_full))

  defp extract(state) do
    %{outcome: outcome, brief: brief} = state
    entries = Enum.reverse(state.transcript)
    facts = %{answered: state.answered?, end_reason: Ending.end_reason(state.ending)}
    opts = [started_at: state.row.dispatch_claimed_at, session_id: state.session_id]
    watchdog_ms = Limits.result_extraction_timeout_ms() + Limits.result_extraction_grace_ms()

    state
    |> start_task(:extract, fn -> extraction(outcome, brief, entries, facts, opts) end)
    |> arm(:extract_watchdog, watchdog_ms)
  end

  defp extraction(outcome, brief, entries, facts, opts) do
    case outcome.extract(brief, entries, facts, opts) do
      {:ok, extracted} -> {:ok, outcome.to_report(extracted)}
      other -> {:error, {:unexpected, other}}
    end
  end

  defp extracted(state, {:ok, %{outcome: word} = outcome}) when is_binary(word),
    do: report_outcome(state, outcome)

  defp extracted(state, other) do
    Logger.warning("phone call #{state.call_id} outcome not read: #{describe(other)}")
    report_outcome(state, unread_outcome(@extraction_failed))
  end

  defp unread_outcome(sentence),
    do: %{outcome: "unknown", outcome_facts: nil, evidence: [], uncertainty: sentence}

  defp report_outcome(state, outcome) do
    failure =
      Ending.failure_reason(state.ending, %{
        engine_stopping?: state.engine_stop?,
        closed?: not is_nil(state.closed),
        hangup_error: state.hangup_error
      })

    report(state, state.dispatch, failure, vendor_message(state), outcome)
  end

  # The one end report, then the worker stops (`noreply/1`); a turn's stop
  # still running ends with it.
  defp report(state, dispatch, failure_reason, vendor_message \\ nil, outcome \\ nil) do
    report =
      EndReport.build(%{
        dispatch: dispatch,
        finalized?: not is_nil(state.closed),
        closed_seconds: state.closed && state.closed.seconds,
        usage_seconds: state.usage_seconds,
        call_failed?: not is_nil(state.call_failed),
        failure_reason: failure_reason,
        vendor_message: vendor_message,
        outcome: outcome,
        finish: state.finish,
        backend_usage: backend_usage(state)
      })

    :ok = Manager.report_end(state.manager, state.call_id, report)

    %{state | phase: :reported, dispatch: dispatch, tasks: Tasks.shutdown_stops(state.tasks)}
  end

  defp vendor_message(%{call_failed: %{} = failure} = state),
    do: failure.message || failure.code || state.vendor_error

  defp vendor_message(state), do: state.vendor_error

  # --- timers and tasks --------------------------------------------------------------------

  defp timer(state, kind, token) do
    case Timers.take(state.timers, kind, token) do
      {:fired, timers} -> fired(%{state | timers: timers}, kind)
      :stale -> state
    end
  end

  defp fired(state, :create_watchdog), do: task_expired(state, :create)
  defp fired(state, :hangup_watchdog), do: task_expired(state, :hangup)
  defp fired(state, :hangup_resend), do: request_hangup(state)
  defp fired(state, :extract_watchdog), do: task_expired(state, :extract)
  defp fired(state, :attach), do: begin_end(state, :attach_timeout)
  defp fired(%{answered?: false} = state, :ringing), do: begin_end(state, :no_answer)
  defp fired(state, :ringing), do: state
  defp fired(state, :deadline), do: begin_end(state, :deadline)
  defp fired(state, :silence), do: begin_end(state, :recipient_silence)
  defp fired(state, {:settle, id}), do: run_turn(state, id)
  defp fired(state, {:turn_timeout, id}), do: turn_timed_out(state, id)
  defp fired(state, :dtmf_ack), do: keypad_done(state, :ack_timeout)
  defp fired(state, :speech), do: speech_check(state)
  defp fired(state, :drain), do: finalize(state)

  defp arm(state, kind, ms), do: %{state | timers: Timers.arm(state.timers, kind, ms)}

  defp arm_at(state, kind, %DateTime{} = at),
    do: arm(state, kind, max(DateTime.diff(at, now(state), :millisecond), 0))

  defp disarm(state, kind), do: %{state | timers: Timers.disarm(state.timers, kind)}
  defp disarm_all(state), do: %{state | timers: Timers.disarm_all(state.timers)}

  defp start_task(state, kind, fun), do: %{state | tasks: Tasks.start(state.tasks, kind, fun)}

  defp task_message(state, ref, message) do
    case Tasks.owner(state.tasks, ref) do
      {:named, kind} -> task_done(%{state | tasks: Tasks.drop(state.tasks, ref)}, kind, message)
      :stop -> stop_answered(%{state | tasks: Tasks.drop(state.tasks, ref)}, message)
      :none -> state
    end
  end

  # A turn's stop has answered, or ended without answering; either way the
  # call goes on as it was (the fencing already holds).
  defp stop_answered(state, {:down, reason}) do
    Logger.warning("phone call #{state.call_id} turn stop ended early: #{describe(reason)}")
    state
  end

  defp stop_answered(state, {:result, _answer}), do: state

  defp task_expired(state, kind) do
    case Tasks.expire(state.tasks, kind) do
      {:result, result, tasks} -> task_done(%{state | tasks: tasks}, kind, {:result, result})
      {:killed, tasks} -> task_done(%{state | tasks: tasks}, kind, {:down, :watchdog})
      :none -> state
    end
  end

  defp task_done(state, :create, message),
    do: state |> disarm(:create_watchdog) |> created(task_result(:create, message))

  defp task_done(state, :hangup, message),
    do: state |> disarm(:hangup_watchdog) |> hangup_answered(task_result(:hangup, message))

  defp task_done(state, :extract, message),
    do: state |> disarm(:extract_watchdog) |> extracted(task_result(:extract, message))

  # A task that crashed, or was stopped at its watchdog, answered nothing.
  defp task_result(_kind, {:result, result}), do: result

  defp task_result(:create, {:down, reason}),
    do: {:error, {:unknown, {:create_stopped, describe(reason)}}}

  defp task_result(:hangup, {:down, reason}),
    do: {:error, {:unknown, {:hangup_stopped, describe(reason)}}}

  defp task_result(:extract, {:down, reason}),
    do: {:error, {:extraction_stopped, describe(reason)}}

  # --- the ledger -------------------------------------------------------------------------

  # Each write below is bounded (`{:error, :timeout}` when the store does not
  # answer). Progress, usage and the closure are records, not guards: one that
  # fails is logged once a call for its kind, and the call goes on.
  defp advance(%{provider_session: nil} = state, _step), do: state

  defp advance(state, step) do
    case state.ledger.advance(state.call_id, step, now(state), server: state.repo) do
      {:ok, _row} -> state
      {:error, reason} -> log_ledger(state, :advance, reason)
    end
  end

  # A guard: anything but `:ok`, a timeout included, means the side effect it
  # pays for does not happen.
  defp consume(state, counter) do
    case state.ledger.consume(state.call_id, counter, server: state.repo) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_usage(state, snapshot, seconds) do
    seconds = Ledger.whole_voice_seconds(seconds)

    case state.ledger.record_usage(state.call_id, snapshot, seconds, server: state.repo) do
      {:ok, _row} -> state
      {:error, reason} -> log_ledger(state, :usage, reason)
    end
  end

  defp record_closure(%{closed: closed} = state) do
    closure = %{at: now(state), reason: closed.reason, voice_seconds: closed.seconds}

    case state.ledger.record_closure(state.call_id, closure, server: state.repo) do
      {:ok, _row} -> state
      {:error, reason} -> log_ledger(state, :closure, reason)
    end
  end

  defp log_ledger(state, kind, reason) do
    if MapSet.member?(state.ledger_logged, kind) do
      state
    else
      Logger.warning("phone call #{state.call_id} #{kind} not recorded: #{describe(reason)}")
      %{state | ledger_logged: MapSet.put(state.ledger_logged, kind)}
    end
  end

  # --- state ------------------------------------------------------------------------------

  defp build_state(args) do
    %Brief{} = brief = Map.fetch!(args, :brief)

    struct!(__MODULE__,
      call_id: Map.fetch!(args, :call_id),
      row: Map.fetch!(args, :row),
      brief: brief,
      manager: Map.fetch!(args, :manager),
      repo: Map.fetch!(args, :repo),
      now_fn: fetch_fun!(args, :now_fn, 0),
      session_id: Map.fetch!(args, :session_id),
      parent_session: Map.fetch!(args, :parent_session),
      registry: Map.get(args, :registry, CallControls.registry_name()),
      transport: Map.get(args, :transport, CallTransport),
      transport_opts: Map.get(args, :transport_opts, []),
      delegate: Map.get(args, :delegate),
      readiness: Map.get(args, :readiness, &Readiness.current/1),
      ledger: Map.get(args, :ledger, Ledger),
      outcome: Map.get(args, :outcome, Outcome),
      prompt: Map.get(args, :prompt, Prompt),
      config: Map.get(args, :config, &Config.get/0),
      credentials: Map.get(args, :credentials, &credentials/1),
      monotonic: Map.get(args, :monotonic, &monotonic_ms/0),
      timers: Timers.new(Map.get(args, :schedule, &send_after/2)),
      tasks: Tasks.new()
    )
  end

  defp fetch_fun!(args, key, arity) do
    case Map.fetch!(args, key) do
      fun when is_function(fun, arity) ->
        fun

      other ->
        raise ArgumentError, "#{key} must be a #{arity}-arity function, got: #{inspect(other)}"
    end
  end

  defp send_after(message, ms), do: Process.send_after(self(), message, ms)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp now(state), do: state.now_fn.()

  # --- helpers ------------------------------------------------------------------------------

  defp api_key do
    case Config.openai_api_key() do
      {:ok, key} -> {:ok, key}
      {:error, :missing_openai_api_key} -> {:error, :openai_api_key_missing}
    end
  end

  defp sip_username(%Config{sip_username: username}) when is_binary(username) and username != "",
    do: {:ok, username}

  defp sip_username(%Config{}), do: {:error, :sip_username_missing}

  defp sip_password(config) do
    case Config.sip_password(config) do
      {:ok, password} -> {:ok, password}
      {:error, :missing_sip_password} -> {:error, :sip_password_missing}
    end
  end

  defp new_handle,
    do: @handle_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp vendor_words(%{} = vendor), do: vendor[:message] || vendor[:code] || vendor[:type]
  defp vendor_words(_vendor), do: nil

  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp describe(term), do: inspect(term, limit: 8, printable_limit: 200)
end
