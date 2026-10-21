defmodule FermixCore.Realtime.LiveSessionServer do
  @moduledoc """
  Owns one local full-duplex call on the OpenAI Live engine.

  The shape of this process follows from three facts about Live that the
  Realtime engine does not share:

    * **The provider runs no tools.** Every piece of work is DELEGATED back to
      Fermix through `FermixCore.Realtime.VoiceBridge`, so this server is a
      dispatcher between a voice frontend and an agent turn, not a tool runner.
      `LiveDelegation` holds the authoritative task state; the transcript is the
      only description of what was asked for.
    * **A Live session is immutable and unrepeatable.** Model, voice,
      instructions, audio format and delegation mode are fixed at
      `session.start`, and its delegations belong to that provider session. So
      there is NO reconnect: a lost socket ends the call with
      `:provider_disconnected` rather than resuming into a session that cannot
      be reconstructed.
    * **It bills by the clock.** `LiveLedger` prices seconds, and the ceiling is
      enforced on a local tick as well as on provider snapshots, because a
      silent call still costs money.

  The call's tasks, their results and what the call leaves behind are
  `CallTasks`, shared with the Grok engine (M70 §03); this server says what
  they tell the voice on Live's own wire, a spoken commentary or a quiet
  thinking line. A hand-off's reply is said as one line, and in a call in the
  chat what cannot be said (a link, code, a table, a long answer) is shown in
  the chat through the bridge, the voice told so only once the row is written
  (`LiveText.split/2`, M56 §4.5). A reply its turn said is drawn from Computer
  History is shown, never said, unless OpenAI may carry it (M56 §9); a private
  call shows nothing.

  Every terminal exit — hang-up, ceiling, expiry, max duration, disconnect —
  runs one settle path: the companion is told the call is idle, in-flight
  delegations are left (below), the provider session is closed gracefully
  (bounded), the ledger is finalized, and `call_stop` telemetry carries WHY.
  `terminate/2` only releases what is still held.

  A private call cancels its in-flight delegations through the bridge. A call
  in the chat hands its running one over instead (M56 §4.6), to finish into
  the chat: the record says it is `detached`, the bridge's owner takes its
  route, and only then is the call's own released; the task frame says so
  (`detached: true`), and the voice is told once that the work goes on in the
  chat. The waiting one is started behind it when its words were heard (the
  check every hand-off passes), and is otherwise dropped, `failed`. A task
  the owner will not take is cancelled as a private call's is, its reason on
  the record. An event of a handed-over task that reached this session before
  its route was released is forwarded to its owner as this process exits.

  A call in the chat leaves a gist and one chat row (M56 §4.2): the settle
  closes the record with the settled cost and what the call owes the chat,
  then hands a snapshot of what was said and the tasks to `CallGist`, under
  the task supervisor, and goes without waiting on it. Whatever drawn from
  Computer History reached the call marks its gist (M56 §9). A private call,
  and one whose provider session never started, owe nothing.
  """

  use GenServer

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.ComputerHistory.Taint
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.CallSpeech
  alias FermixCore.Realtime.CallTasks
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.ConversationRecorder
  alias FermixCore.Realtime.DeviceIdentity
  alias FermixCore.Realtime.LiveChat
  alias FermixCore.Realtime.LiveFrames
  alias FermixCore.Realtime.LiveLedger
  alias FermixCore.Realtime.LivePrompt
  alias FermixCore.Realtime.LiveTelemetry
  alias FermixCore.Realtime.LiveText
  alias FermixCore.Realtime.LiveTranscript
  alias FermixCore.Realtime.LiveTurn
  alias FermixCore.Realtime.OpenAILiveClient
  alias FermixCore.Realtime.VoiceBridge

  require Logger

  @minute_ms 60_000

  # Bounds the design fixes (M41 §8). All internal constants: the operator
  # configures a ceiling and a max duration, not a protocol.
  @start_deadline_ms 5_000
  @close_deadline_ms 15_000
  @usage_tick_ms 5_000
  # How long after its audio has had time to play a reply counts as over: the
  # pet buffers a little before it plays.
  @reply_margin_ms 300
  # The microphone held while the provider session starts: ten seconds of
  # 24 kHz PCM16, more than a slow connect and the start deadline together, so
  # a start that succeeds loses none of the first words, and a bound on what a
  # start that hangs can hold before the deadline ends the call.
  @max_held_audio_bytes 480_000

  # Live caps an append at 500 tokens. This byte bound sits under that with
  # room for multibyte text, and it is what stops a 40 KB progress dump from
  # being read aloud (`CallTasks` bounds what is said of a result).
  @thinking_max_bytes 1_200
  # Unacked appends are kept only to explain a provider error. Bounded: this
  # process lives for a whole call.
  @max_pending_appends 64

  @insufficient_context "I did not catch that, could you say it again?"
  @interrupt_instruction "Stop speaking now and listen."
  @cancelled_line "The task was cancelled."
  @submit_failed_line "I could not start that task."
  @busy_line "I am already working on a task and one more is waiting."

  # What the voice is told, once before the call closes, when work it handed
  # off goes on into the chat (M56 §4.6).
  @detached_line "The call is ending. The work you handed off goes on, and its result " <>
                   "will be in the owner's chat."
  # The events of handed-over tasks forwarded as this process exits. A task
  # sends a handful, and its route is gone by then.
  @max_forwarded 256

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :session_scope, make_ref())},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "The provider socket process, or `nil` before `call_start`."
  @spec live_pid(GenServer.server()) :: pid() | nil
  def live_pid(server), do: GenServer.call(server, :live_pid)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.get_lazy(opts, :config, &Config.current/0)

    if Config.live?(config) do
      claim_call(initial_state(opts, config))
    else
      {:stop, {:invalid_engine, config.engine}}
    end
  end

  # One call per daemon (M56 §4.8). The claim is taken before this session exists
  # to its caller, so a second `call_start` is refused before it can open a
  # provider session that bills by the minute; the socket answers it
  # `call_in_progress` and closes the connection. Held until this process exits,
  # so a call still settling counts. It names the call's conversation and start,
  # so a typed chat turn can tell a call in the chat from a private one without
  # asking this process (M56 §4.4).
  defp claim_call(state) do
    call = %{
      call_uuid: state.call_uuid,
      conversation: Config.conversation(state.config),
      started_at: state.started_at
    }

    case CallRegistry.claim(state.call_registry, call) do
      :ok ->
        {:ok, state}

      {:error, :call_in_progress} ->
        Logger.info("voice_live: refused a second call while one is in progress")
        {:stop, :call_in_progress}
    end
  end

  defp initial_state(opts, config) do
    clock = Keyword.get(opts, :clock, &monotonic_ms/0)
    session_scope = Keyword.get(opts, :session_scope, "voice_live:unknown")
    companion = Keyword.fetch!(opts, :companion)
    # The trace session id, a counter that restarts with the VM.
    call_id = to_string(session_scope)
    # The call's durable identity: the key of its record, on every frame and
    # telemetry event that names the call.
    call_uuid = DeviceIdentity.generate_uuid()
    device_id = Keyword.get(opts, :device_id, "unknown")

    %{
      companion: companion,
      config: config,
      call_id: call_id,
      call_uuid: call_uuid,
      # When the call started: the claim's and the record's one start, and the
      # same moment on this session's clock, for how long it has run.
      started_at: DateTime.utc_now(),
      started_ms: clock.(),
      call_registry: Keyword.get(opts, :call_registry, CallRegistry),
      api_key: Keyword.get(opts, :api_key),
      device_id: device_id,
      agent_id: Keyword.get(opts, :agent_id, MemoryConfig.agent_id()),
      live_client: Keyword.get(opts, :live_client, OpenAILiveClient),
      live_pid: nil,
      voice_bridge: Keyword.get(opts, :voice_bridge),
      # The call's tasks, their record and what the call leaves the chat.
      tasks:
        [
          call_id: call_id,
          call_uuid: call_uuid,
          conversation: Config.conversation(config),
          device_id: device_id,
          voice_provider: :openai,
          meta: telemetry_meta(config, call_id, call_uuid, device_id),
          clock: clock,
          record_opts: CallRecord.repo_opts(Keyword.get(opts, :record_repo, Repo)),
          persist?: config.persist_transcripts?
        ]
        |> Keyword.merge(Keyword.take(opts, [:context_wait_ms]))
        |> CallTasks.new(),
      capability_registry: Keyword.get(opts, :capability_registry, CapabilityRegistry),
      prompt: Keyword.get(opts, :prompt),
      recorder_module: Keyword.get(opts, :recorder_module, ConversationRecorder),
      recorder_opts: Keyword.get(opts, :recorder_opts, []),
      clock: clock,
      unix_clock: Keyword.get(opts, :unix_clock, &unix_seconds/0),
      start_deadline_ms: Keyword.get(opts, :start_deadline_ms, @start_deadline_ms),
      close_deadline_ms: Keyword.get(opts, :close_deadline_ms, @close_deadline_ms),
      usage_tick_ms: Keyword.get(opts, :usage_tick_ms, @usage_tick_ms),
      reply_margin_ms: Keyword.get(opts, :reply_margin_ms, @reply_margin_ms),
      provider_ready?: false,
      provider_session_id: nil,
      expires_at: nil,
      max_duration_ms: config.max_session_minutes * @minute_ms,
      muted?: false,
      provider_muted?: false,
      speaking?: false,
      turn: LiveTurn.new(),
      closing?: false,
      closed_report: :never,
      ledger: LiveLedger.new(config.max_estimated_cost_cents_per_session, clock.()),
      transcript: LiveTranscript.new(),
      # The whole call's speech, for a call in the chat (M56 §4.4).
      speech: CallSpeech.new(),
      # The gist's summariser seams (`CallGist.run/2`'s opts); a test names a
      # route, the daemon names none and the primary chain is used.
      gist_opts: Keyword.get(opts, :gist, []),
      pending_appends: [],
      # The microphone from `listening` until the provider session is up,
      # newest first, and its size (`@max_held_audio_bytes`).
      held_audio: [],
      held_audio_bytes: 0,
      # What `session.start` carried, `nil` until it is sent: kept so a start
      # the provider refused over its input can be sent once more without it.
      start: nil,
      start_timer: nil,
      max_session_timer: nil,
      usage_timer: nil,
      reply_timer: nil
    }
  end

  @impl true
  def handle_call(:call_start, _from, %{live_pid: nil} = state) do
    case start_call(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:call_start, _from, state), do: {:reply, :ok, state}

  def handle_call({:interrupt, _audio_end_ms}, _from, state) do
    notify(state, LiveFrames.playback_stop())

    state =
      %{state | turn: LiveTurn.interrupted(state.turn, now(state))}
      |> cancel_reply_timer()
      |> notify_state("listening")
      |> send_append(
        OpenAILiveClient.instructions_append_event(
          OpenAILiveClient.new_event_id(),
          nil,
          @interrupt_instruction
        ),
        :instructions,
        nil
      )

    {:reply, :ok, state}
  end

  # The local gate applies FIRST and unconditionally: a microphone privacy
  # control that waited for a provider round trip would keep streaming the
  # operator's room while it waited.
  def handle_call({:mute, enabled?}, _from, state) do
    state =
      %{state | muted?: enabled?, turn: LiveTurn.muted(state.turn)}
      |> notify_state(if(enabled?, do: "muted", else: "listening"))
      |> send_mute(enabled?)

    {:reply, :ok, state}
  end

  # `SessionControl` waits for `cancel_task` and `call_stop` with no timeout, so
  # both must stay bounded. A cancel is one bridge cancel (the Queue's stop of
  # that hand-off's turn, however long a busy Queue takes to reach it) and then
  # the next delegation's submit. A stop is `settle/2`: at most one bridge
  # cancel (only the active delegation reached the bridge), or, in a call in
  # the chat, at most one submit and two hand-overs (each one call into the
  # owner, whose callbacks are bounded), the bridge close (one stop for each
  # turn the call registered, bounded by the call's length, and the call
  # store's release), and the graceful close: one send, then at most
  # `close_deadline_ms` waiting for `session.closed`. The stop's reply goes
  # out after `terminate/2`, so the wait covers that too: it cancels timers,
  # finds the bridge call already closed, forwards what reached it of a
  # handed-over task (at most `@max_forwarded` events, none waited for), and
  # casts the socket close.
  def handle_call({:cancel_task, delegation_id}, _from, state) do
    case CallTasks.cancel(state.tasks, delegation_id, state.transcript) do
      {:ok, tasks, told} -> {:reply, :ok, tell(%{state | tasks: tasks}, told)}
      {:error, :unknown_delegation} -> {:reply, {:error, :unknown_delegation}, state}
    end
  end

  def handle_call(:call_stop, _from, state) do
    {:stop, {:shutdown, :call_stop}, :ok, settle(state, :call_stop)}
  end

  # A Live session is immutable once started: instructions, voice and model are
  # fixed at `session.start`. Saying so is the honest answer; silently sending
  # an update the wire has no event for would not be.
  def handle_call(:reload_runtime, _from, state) do
    {:reply, {:ok, %{tools: 0, applies: :next_call}}, state}
  end

  def handle_call(:live_pid, _from, state), do: {:reply, state.live_pid, state}

  def handle_call(:call_context, _from, state) do
    context = %{
      call_uuid: state.call_uuid,
      started_at: state.started_at,
      elapsed_ms: max(0, now(state) - state.started_ms),
      tasks: CallTasks.recorded_tasks(state.tasks),
      speech: state.speech
    }

    {:reply, {:ok, context}, state}
  end

  @impl true
  def handle_cast({:chat, event}, state), do: {:noreply, mirror_chat(state, event)}

  def handle_cast({:audio_chunk, audio}, state) do
    case audio_route(state, audio) do
      :send ->
        state = send_provider(state, OpenAILiveClient.audio_append_event(audio))
        {:noreply, advance_operator_turn(state)}

      :hold ->
        {:noreply, hold_audio(state, audio)}

      {:drop, reason} ->
        {:noreply, drop_audio(state, reason)}
    end
  end

  @impl true
  def handle_info({:openai_live_event, event}, state), do: handle_live_event(event, state)

  def handle_info({:openai_live_error, reason}, state) do
    Logger.warning("voice_live: provider frame unreadable: #{inspect(reason)}")
    LiveTelemetry.provider_error(state.tasks.meta, inspect(reason))
    {:noreply, state}
  end

  def handle_info({:openai_live_disconnect, _status}, %{closing?: true} = state),
    do: {:noreply, state}

  def handle_info({:openai_live_disconnect, status}, state) do
    Logger.warning("voice_live: provider socket disconnected: #{inspect(status)}")
    end_call(state, :provider_disconnected)
  end

  def handle_info({:EXIT, pid, _reason}, %{live_pid: pid, closing?: true} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{live_pid: pid} = state) do
    Logger.warning("voice_live: provider socket exited: #{inspect(reason)}")
    end_call(state, :provider_disconnected)
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.debug("voice_live: linked process #{inspect(pid)} exited: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(:start_deadline, %{provider_ready?: false} = state) do
    Logger.warning("voice_live: provider never acknowledged session.start")
    end_call(state, :provider_refused)
  end

  def handle_info(:start_deadline, state), do: {:noreply, state}

  def handle_info(:max_session_duration, state), do: end_call(state, :max_session_duration)

  def handle_info(:usage_tick, state) do
    state = %{state | ledger: LiveLedger.tick(state.ledger, now(state))}
    notify_usage(state)
    enforce_ceiling(schedule_usage_tick(state))
  end

  def handle_info({:reply_played_out, token}, %{reply_timer: {_timer, token}} = state) do
    state = %{state | reply_timer: nil}
    {:noreply, if(state.speaking?, do: notify_state(state, "listening"), else: state)}
  end

  def handle_info({:reply_played_out, _stale_token}, state), do: {:noreply, state}

  def handle_info({:context_wait_expired, delegation_id, revision}, state) do
    {tasks, told} =
      CallTasks.context_wait_expired(state.tasks, delegation_id, revision, state.transcript)

    {:noreply, tell(%{state | tasks: tasks}, told)}
  end

  def handle_info({:delegation_event, delegation_id, revision, event}, state) do
    {tasks, told} =
      CallTasks.delegation_event(state.tasks, delegation_id, revision, event, state.transcript)

    {:noreply, tell(%{state | tasks: tasks}, told)}
  end

  # A confirmed access-sensitive command finished, or crashed: its outcome
  # answers the task that carried the owner's yes, like any task's result.
  def handle_info({ref, _outcome} = message, state) when is_reference(ref),
    do: access_message(message, state)

  def handle_info({:DOWN, ref, :process, _pid, _reason} = message, state) when is_reference(ref),
    do: access_message(message, state)

  def handle_info(message, state) do
    Logger.debug("voice_live: unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{companion: _companion} = state) do
    state = cancel_timers(state)
    tasks = CallTasks.close_bridge_call(state.tasks)
    CallTasks.forward_detached(tasks, @max_forwarded)
    close_socket(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Call start

  defp start_call(state) do
    state = listen_while_starting(state)

    with {:ok, bridge} <- resolve_bridge(state),
         {:ok, instructions} <- resolve_prompt(state),
         {:ok, {input, input_tainted?}} <- resolve_input(state, bridge),
         {:ok, api_key} <- require_binary(state.api_key, :api_key),
         {:ok, pid} <- open_socket(state, api_key) do
      tasks = state.tasks |> CallTasks.put_bridge(bridge) |> taint_if(input_tainted?)
      state = %{state | voice_bridge: bridge, live_pid: pid, tasks: tasks}
      send_session_start(state, instructions, input)
    else
      {:error, {:provider_refused, reason}} -> refuse_start(state, reason)
      {:error, reason} -> {:error, reason, notify_error(state, reason)}
    end
  end

  # The person may speak from the moment the call is accepted: what they say is
  # held until the provider session is up and then passed on in order
  # (`release_held_audio/1`). The start behind it, the call's context, the
  # connect and the provider's session start, is over a second, so the pet
  # listens as soon as its microphone is up rather than after all of it. A
  # start that fails says so with an error frame, a local failure within
  # moments.
  defp listen_while_starting(state), do: notify_state(state, "listening")

  # The provider answered the handshake with a refusal — a 401 for a stale or
  # wrong key is the common one. Its own sentence is the only diagnosis anyone
  # gets, so it reaches the trace AND the companion's `detail` before the caller
  # is answered; a bare `provider_refused` sends the operator hunting a phantom.
  # The session stays up: the call never opened, and a crash here would close
  # the companion's connection with no frame on it at all.
  defp refuse_start(state, reason) do
    detail = LiveText.reason(reason)
    Logger.warning("voice_live: the provider refused the session: #{detail}")
    LiveTelemetry.provider_error(state.tasks.meta, detail)
    notify(state, LiveFrames.error(:provider_refused, detail))
    {:error, :provider_refused, state}
  end

  defp send_session_start(state, instructions, input) do
    event =
      OpenAILiveClient.session_start_event(state.config, instructions,
        event_id: OpenAILiveClient.new_event_id(),
        input: input
      )

    case send_event(state, event) do
      :ok ->
        LiveTelemetry.call_start(
          state.tasks.meta,
          state.max_duration_ms,
          Map.put(LiveChat.input_size(input), :instructions_bytes, byte_size(instructions))
        )

        state = %{state | start: %{instructions: instructions, input: input}}
        {:ok, state |> open_record() |> arm_start_deadline()}

      {:error, reason} ->
        close_socket(state)
        {:error, reason, notify_error(%{state | live_pid: nil}, reason)}
    end
  end

  defp resolve_bridge(%{voice_bridge: module}) when is_atom(module) and not is_nil(module),
    do: {:ok, module}

  defp resolve_bridge(_state), do: VoiceBridge.resolve()

  defp resolve_prompt(%{prompt: prompt}) when is_binary(prompt), do: {:ok, prompt}

  defp resolve_prompt(state) do
    conversation = Config.conversation(state.config)

    with {:ok, live_md} <- LivePrompt.load(state.agent_id),
         {:ok, context} <- LivePrompt.context(state.agent_id, conversation) do
      capabilities = LivePrompt.eligible_capabilities(state.capability_registry, conversation)
      {:ok, LivePrompt.compose(live_md, capabilities, context)}
    end
  end

  # A call in the chat's conversation starts with the chat (M56 §4.3, D6),
  # read through the bridge before the call has a handle. A private call reads
  # none of it. A chat that cannot be read refuses the call, as a LIVE.md that
  # cannot be read does: the call does not start on half of what it was meant
  # to know. With the input, whether it gives the voice anything drawn from
  # Computer History (M56 §9).
  defp resolve_input(state, bridge) do
    case Config.conversation(state.config) do
      "chat" -> chat_input(bridge)
      "private" -> {:ok, {[], false}}
    end
  end

  defp chat_input(bridge) do
    with {:ok, window} <- bridge.conversation_window(LiveChat.window_bounds()) do
      {:ok, {LiveChat.input(window), LiveChat.carries_taint?(window, :openai)}}
    end
  end

  defp taint_if(tasks, true), do: CallTasks.mark_tainted(tasks)
  defp taint_if(tasks, false), do: tasks

  # Tagged, because `start_call/1`'s `with` gathers five different failures and
  # only this one is the provider's: the others (no bridge, no key) are local
  # conditions with their own published kinds and no vendor words to quote.
  defp open_socket(state, api_key) do
    case state.live_client.start_link(
           url: OpenAILiveClient.url(),
           headers: OpenAILiveClient.headers(api_key),
           parent: self()
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:provider_refused, reason}}
    end
  end

  ## Provider events

  defp handle_live_event({:session_started, %{id: id, expires_at: expires_at}}, state) do
    tasks = CallTasks.put_meta(state.tasks, %{provider_session_id: id})

    state =
      %{state | provider_ready?: true, provider_session_id: id, expires_at: expires_at}
      |> Map.put(:tasks, tasks)
      |> cancel_start_timer()

    case CallTasks.open_bridge_call(state.tasks) do
      {:ok, tasks} ->
        state = %{state | tasks: tasks}
        LiveTelemetry.session_started(state.tasks.meta)

        state =
          state
          |> start_timers()
          |> sync_mute()
          |> notify_call_ready()
          |> release_held_audio()

        {:noreply, state}

      {:error, reason} ->
        Logger.error("voice_live: the voice bridge refused the call: #{inspect(reason)}")
        end_call(state, :bridge_unavailable)
    end
  end

  defp handle_live_event({:audio_delta, delta}, state) do
    case LiveTurn.output(state.turn, delta, now(state)) do
      {:voice, turn, plays_for_ms} ->
        {:noreply, forward_reply_audio(%{state | turn: turn}, delta, plays_for_ms)}

      # Live pads its output with silence between replies, and the pet plays
      # the stream as it comes; padding is not speech.
      {:silence, turn} ->
        notify(state, LiveFrames.audio_delta(delta))
        {:noreply, %{state | turn: turn}}

      {:drop, turn} ->
        {:noreply, %{state | turn: turn}}
    end
  end

  defp handle_live_event({:transcript_delta, speaker, delta, start_ms, end_ms}, state) do
    state = %{
      state
      | transcript: LiveTranscript.append(state.transcript, speaker, delta, start_ms, end_ms),
        speech: keep_speech(state, speaker, delta)
    }

    notify(state, LiveFrames.caption(Atom.to_string(speaker), delta, start_ms, end_ms))

    record_caption(state, speaker, delta, start_ms, end_ms)
    {:noreply, read_operator_words(state, speaker)}
  end

  defp handle_live_event({:delegation_created, id, offset_ms}, state) do
    {_admitted, tasks, told} = CallTasks.create(state.tasks, id, offset_ms, state.transcript)
    {:noreply, tell(%{state | tasks: tasks}, told)}
  end

  defp handle_live_event({:usage_updated, seconds}, state) do
    state = %{state | ledger: LiveLedger.observe_usage(state.ledger, seconds, now(state))}
    notify_usage(state)
    enforce_ceiling(state)
  end

  defp handle_live_event({:session_closed, reason, seconds}, state) do
    state = %{state | closed_report: {:reported, seconds}}
    Logger.info("voice_live: provider closed the session (#{reason})")
    end_call(state, closed_reason(reason))
  end

  defp handle_live_event({:input_muted, muted?}, state) do
    {:noreply, %{state | provider_muted?: muted?}}
  end

  defp handle_live_event({:append_acked, kind, event_id}, state) do
    Logger.debug("voice_live: #{kind} append #{inspect(event_id)} acknowledged")
    {:noreply, drop_pending_append(state, event_id)}
  end

  # NOT terminal on its own: a moderation refusal cuts the audio and the session
  # keeps running. The companion is deliberately not told — it treats `error` as
  # the end of the call.
  defp handle_live_event({:error, error}, state) do
    if refused_input?(state, error) do
      {:noreply, start_without_input(state, error)}
    else
      Logger.warning("voice_live: provider error: #{inspect(error)}")
      LiveTelemetry.provider_error(state.tasks.meta, provider_error_text(error))
      {:noreply, fail_pending_append(state, Map.get(error, "client_event_id"))}
    end
  end

  defp handle_live_event({:info, code, message}, state) do
    Logger.info("voice_live: provider info #{inspect(code)}: #{inspect(message)}")
    {:noreply, state}
  end

  defp handle_live_event({:session_updated, _event}, state), do: {:noreply, state}

  defp handle_live_event({:unhandled, "session.delegation.created", event}, state) do
    Logger.warning(
      "voice_live: ignoring a delegation this engine does not own: #{inspect(event)}"
    )

    {:noreply, state}
  end

  defp handle_live_event({:unhandled, type, _event}, state) do
    Logger.debug("voice_live: unhandled provider event #{type}")
    {:noreply, state}
  end

  # A decoded shape with no clause above. Logged, never fatal: one unrecognised
  # provider event must not end a call that is otherwise healthy.
  defp handle_live_event(event, state) do
    Logger.debug("voice_live: no handler for provider event #{inspect(event)}")
    {:noreply, state}
  end

  # A private call keeps only the hand-off window, as it always did (M56 §5).
  defp keep_speech(state, speaker, delta) do
    case Config.conversation(state.config) do
      "chat" -> CallSpeech.append(state.speech, speaker, delta)
      "private" -> state.speech
    end
  end

  # M56 §8: a start the provider refused over its input. Before
  # `session.started` nothing but `session.start` can have been sent, and the
  # provider names the field it refused in `param`, so an error naming
  # `session.input` is that refusal. Only a start that carried input matches,
  # and the retry carries none, so it is sent once at most.
  defp refused_input?(%{provider_ready?: false, start: %{input: [_ | _]}}, %{"param" => param})
       when is_binary(param),
       do:
         param == "session.input" or
           String.starts_with?(param, ["session.input[", "session.input."])

  defp refused_input?(_state, _error), do: false

  # The call proceeds without the chat. Logged and traced with the field and
  # the code only: the vendor's message may quote the chat text it refused.
  defp start_without_input(state, error) do
    detail = "#{Map.get(error, "code") || Map.get(error, "type")} (#{Map.fetch!(error, "param")})"

    Logger.warning(
      "voice_live: the provider refused the call's input, starting without it: #{detail}"
    )

    LiveTelemetry.provider_error(state.tasks.meta, detail)

    event =
      OpenAILiveClient.session_start_event(state.config, state.start.instructions,
        event_id: OpenAILiveClient.new_event_id()
      )

    %{state | start: %{state.start | input: []}}
    |> cancel_start_timer()
    |> send_provider(event)
    |> arm_start_deadline()
  end

  # M56 §4.3: the chat, mirrored as session-wide quiet context (a thinking
  # append with no delegation), only while the provider session is up and the
  # call is in the chat's conversation. A private call is told nothing.
  defp mirror_chat(state, event) do
    case mirror_line(state, event) do
      {:ok, line} ->
        state |> send_thinking(nil, line) |> mirrored_taint(event)

      :drop ->
        Logger.debug("voice_live: a chat #{elem(event, 0)} message was not mirrored")
        state
    end
  end

  defp mirror_line(%{provider_ready?: true, closing?: false} = state, event) do
    case Config.conversation(state.config) do
      "chat" -> LiveChat.mirror_line(event, :openai)
      "private" -> :drop
    end
  end

  defp mirror_line(_state, _event), do: :drop

  # An answer is mirrored stamped only while the voice may carry it, and then
  # the call has heard something drawn from Computer History (M56 §9).
  defp mirrored_taint(state, {:answered, message}),
    do: %{state | tasks: taint_if(state.tasks, Taint.tainted?(message))}

  defp mirrored_taint(state, {:typed, _text}), do: state

  # A mute applied before `session.started` was gated locally but never reached
  # the provider — it had no session to reach. It does now.
  defp sync_mute(%{muted?: true} = state), do: send_mute(state, true)
  defp sync_mute(state), do: state

  ## What the call's tasks tell the voice

  # `CallTasks` decides what the voice is told; Live says it as a spoken
  # commentary on the task, or as a quiet thinking line it may use without
  # saying. Live never revises a task, so `{:superseded, _}` has no clause:
  # it would be a defect, and it fails loud.
  defp tell(state, told), do: Enum.reduce(told, state, &say/2)

  defp say({:clarify, record}, state),
    do: send_append(state, commentary(record.id, @insufficient_context), :commentary, record.id)

  defp say({:submit_failed, record}, state),
    do: send_append(state, commentary(record.id, @submit_failed_line), :commentary, record.id)

  defp say({:progress, record, text}, state),
    do: send_thinking(state, record.id, LiveText.one_line(text, @thinking_max_bytes))

  defp say({:tool_started, record, name}, state),
    do: send_thinking(state, record.id, "Using " <> name)

  # A completed task is a backend turn the ledger counts, never prices.
  defp say({:completed, record, spoken}, state) do
    %{state | ledger: LiveLedger.record_backend_turn(state.ledger, %{})}
    |> send_append(commentary(record.id, spoken), :commentary, record.id)
  end

  defp say({:cancelled, record}, state), do: send_thinking(state, record.id, @cancelled_line)

  defp say({:failed, record, sentence}, state),
    do: send_append(state, commentary(record.id, sentence), :commentary, record.id)

  # The third task. Live is told out loud that Fermix is busy, so it can say so.
  defp say({:busy, id}, state), do: send_thinking(state, id, @busy_line)

  defp say(:handed_over, state), do: send_thinking(state, nil, @detached_line)

  defp say({:frame, frame}, state) do
    notify(state, frame)
    state
  end

  defp access_message(message, state) do
    case CallTasks.access_message(state.tasks, message, state.transcript) do
      {:ok, tasks, told} ->
        {:noreply, tell(%{state | tasks: tasks}, told)}

      :unknown ->
        Logger.debug("voice_live: unexpected message #{inspect(message)}")
        {:noreply, state}
    end
  end

  ## Teardown

  defp end_call(state, reason), do: {:stop, {:shutdown, reason}, settle(state, reason)}

  # THE terminal path. Every way a call can end runs it, in this order, so the
  # companion, the bridge, the provider and the ledger are never left disagreeing
  # about whether the call is over.
  defp settle(%{closing?: true} = state, _reason), do: state

  defp settle(state, reason) do
    state =
      %{state | closing?: true}
      |> notify_state("idle")
      |> notify_terminal(reason)
      |> leave_tasks()

    state = %{state | tasks: CallTasks.close_bridge_call(state.tasks)}

    {seconds, state} = graceful_close(state)
    state = %{state | ledger: LiveLedger.finalize(state.ledger, seconds)}

    ending = ending(state, reason)
    owes = CallTasks.close_record(state.tasks, ending)
    notify_usage(state)
    LiveTelemetry.call_stop(state.tasks.meta, call_measurements(state), reason)
    CallTasks.leave_for_chat(state.tasks, ending, owes)
    cancel_timers(state)
  end

  # A private call's tasks are cancelled; a call in the chat hands its running
  # one over (M56 §4.6), and the voice is told once that the work goes on.
  defp leave_tasks(state) do
    {tasks, told} = CallTasks.leave(state.tasks, state.transcript)
    tell(%{state | tasks: tasks}, told)
  end

  defp ending(state, reason) do
    %{
      reason: reason,
      usage: LiveLedger.usage_payload(state.ledger),
      speech: state.speech,
      started_at: state.started_at,
      provider_started?: not is_nil(state.provider_session_id),
      gist_opts: state.gist_opts
    }
  end

  defp notify_terminal(state, :call_stop), do: state

  defp notify_terminal(state, :cost_limit) do
    state
    |> notify_usage("limit_reached")
    |> notify_error(:cost_limit)
  end

  defp notify_terminal(state, reason), do: notify_error(state, reason)

  # A call whose provider session already closed, or never opened, has nothing
  # to hand back — asking anyway would block the whole close deadline on a
  # socket that cannot answer.
  defp graceful_close(%{live_pid: nil} = state), do: {0, state}
  defp graceful_close(%{closed_report: {:reported, seconds}} = state), do: {seconds, state}

  defp graceful_close(state) do
    case send_event(state, OpenAILiveClient.close_event(OpenAILiveClient.new_event_id())) do
      :ok ->
        {await_session_closed(state.close_deadline_ms), state}

      {:error, reason} ->
        Logger.warning("voice_live: session.close could not be sent: #{inspect(reason)}")
        {nil, state}
    end
  end

  # A selective receive, deliberately: the mailbox still holds audio deltas and
  # captions for a call that is over, and none of them settle the bill.
  defp await_session_closed(deadline_ms) do
    receive do
      {:openai_live_event, {:session_closed, _reason, seconds}} ->
        seconds
    after
      deadline_ms ->
        Logger.warning("voice_live: no session.closed within the close deadline")
        nil
    end
  end

  defp closed_reason("expired"), do: :session_expired
  defp closed_reason(_reason), do: :provider_disconnected

  ## Companion frames

  defp notify(%{companion: companion}, frame) when is_pid(companion) do
    send(companion, {:realtime, frame})
    :ok
  end

  defp notify_state(state, value) do
    notify(state, LiveFrames.state(value))
    %{state | speaking?: value == "speaking"}
  end

  # The reply's audio goes to the pet, and the pet hears when it has played out
  # (Live sends no end of a reply).
  defp forward_reply_audio(state, delta, plays_for_ms) do
    state = if state.speaking?, do: state, else: notify_state(state, "speaking")
    notify(state, LiveFrames.audio_delta(delta))
    arm_reply_timer(state, plays_for_ms + state.reply_margin_ms)
  end

  # The operator's turn, from Live's recognition of their words: a fragment is
  # them speaking, and the microphone's steady chunks are the clock that notices
  # when the words have stopped. Live reports neither turn boundary itself.
  defp read_operator_words(state, :user) do
    {signal, turn} = LiveTurn.words(state.turn, now(state), state.speaking?)
    move_turn(%{state | turn: turn}, signal)
  end

  defp read_operator_words(state, _speaker), do: state

  defp advance_operator_turn(state) do
    {signal, turn} = LiveTurn.tick(state.turn, now(state), state.speaking?)
    move_turn(%{state | turn: turn}, signal)
  end

  defp move_turn(state, nil), do: state
  defp move_turn(state, :thinking), do: notify_state(state, "thinking")
  defp move_turn(state, :listening), do: notify_state(state, "listening")

  defp notify_call_ready(state) do
    notify(
      state,
      LiveFrames.call_ready(
        state.config.engine,
        state.call_id,
        state.call_uuid,
        Config.conversation(state.config),
        state.provider_session_id,
        state.expires_at
      )
    )

    state
  end

  defp notify_usage(state, status \\ nil) do
    notify(
      state,
      LiveFrames.usage(state.call_uuid, LiveLedger.usage_payload(state.ledger), status)
    )

    state
  end

  defp notify_error(state, reason) do
    notify(state, LiveFrames.error(reason))
    state
  end

  ## Provider sends

  defp send_provider(state, event) do
    case send_event(state, event) do
      :ok -> state
      {:error, reason} -> report_send_error(state, reason)
    end
  end

  defp send_thinking(state, delegation_id, content) do
    send_append(
      state,
      OpenAILiveClient.thinking_append_event(
        OpenAILiveClient.new_event_id(),
        delegation_id,
        content
      ),
      :thinking,
      delegation_id
    )
  end

  defp commentary(delegation_id, content) do
    OpenAILiveClient.commentary_append_event(
      OpenAILiveClient.new_event_id(),
      delegation_id,
      content
    )
  end

  defp send_append(state, {event_id, event}, kind, delegation_id) do
    case send_event(state, event) do
      :ok -> track_pending_append(state, event_id, kind, delegation_id)
      {:error, reason} -> report_send_error(state, reason)
    end
  end

  defp send_mute(%{provider_ready?: false} = state, _enabled?), do: state

  defp send_mute(state, enabled?) do
    send_provider(state, OpenAILiveClient.mute_event(OpenAILiveClient.new_event_id(), enabled?))
  end

  defp send_event(%{live_pid: nil}, _event), do: {:error, :provider_not_connected}

  defp send_event(state, event) do
    state.live_client.send_event(state.live_pid, event)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # A failed send is REPORTED, never fatal. Connection liveness has exactly one
  # owner — the disconnect/EXIT clauses — and a second one that tore the call
  # down here would race it.
  defp report_send_error(state, reason) do
    Logger.warning("voice_live: provider send failed: #{inspect(reason)}")
    LiveTelemetry.provider_error(state.tasks.meta, inspect(reason))
    state
  end

  defp track_pending_append(state, event_id, kind, delegation_id) do
    entry = {event_id, kind, delegation_id}
    %{state | pending_appends: Enum.take([entry | state.pending_appends], @max_pending_appends)}
  end

  defp drop_pending_append(state, nil), do: state

  defp drop_pending_append(state, event_id) do
    %{
      state
      | pending_appends: Enum.reject(state.pending_appends, &(elem(&1, 0) == event_id))
    }
  end

  defp fail_pending_append(state, nil), do: state

  defp fail_pending_append(state, event_id) do
    case Enum.find(state.pending_appends, &(elem(&1, 0) == event_id)) do
      nil ->
        state

      {_id, kind, delegation_id} ->
        Logger.warning(
          "voice_live: the provider refused a #{kind} append for #{inspect(delegation_id)}"
        )

        drop_pending_append(state, event_id)
    end
  end

  # A chunk goes to the provider once its session is up, is held while the
  # session starts (the socket is open and `session.start` sent), and is
  # dropped otherwise.
  defp audio_route(%{muted?: true}, _audio), do: {:drop, :muted}

  defp audio_route(_state, audio) when rem(byte_size(audio), 2) != 0,
    do: {:drop, :odd_pcm16_frame}

  defp audio_route(%{provider_ready?: true}, _audio), do: :send

  defp audio_route(%{live_pid: pid, closing?: false}, _audio) when is_pid(pid), do: :hold

  defp audio_route(_state, _audio), do: {:drop, :provider_not_ready}

  defp hold_audio(state, audio) do
    held = state.held_audio_bytes + byte_size(audio)

    if held > @max_held_audio_bytes do
      drop_audio(state, :held_audio_full)
    else
      %{state | held_audio: [audio | state.held_audio], held_audio_bytes: held}
    end
  end

  defp drop_audio(state, reason) do
    Logger.debug("voice_live: dropped microphone chunk (#{reason})")
    state
  end

  # The provider session is up: what the person said while it started goes to
  # it first, oldest first, and the turn reads it as it reads any speech.
  defp release_held_audio(%{held_audio: []} = state), do: state

  defp release_held_audio(state) do
    state =
      state.held_audio
      |> Enum.reverse()
      |> Enum.reduce(state, &send_provider(&2, OpenAILiveClient.audio_append_event(&1)))

    advance_operator_turn(%{state | held_audio: [], held_audio_bytes: 0})
  end

  ## The call record

  # Opened as `session.start` goes out, before any task can exist.
  defp open_record(state),
    do: %{
      state
      | tasks: CallTasks.open_record(state.tasks, state.config.engine, state.started_at)
    }

  ## Bridge, recorder, timers

  defp record_caption(%{config: %Config{persist_transcripts?: false}}, _s, _d, _from, _to),
    do: :ok

  defp record_caption(state, speaker, delta, start_ms, end_ms) do
    opts =
      Keyword.merge(state.recorder_opts,
        session_scope: state.call_id,
        start_ms: start_ms,
        end_ms: end_ms
      )

    case state.recorder_module.record_caption(
           state.config,
           state.device_id,
           Atom.to_string(speaker),
           delta,
           opts
         ) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("voice_live: caption not recorded: #{inspect(reason)}")
    end
  end

  defp arm_start_deadline(state) do
    %{state | start_timer: Process.send_after(self(), :start_deadline, state.start_deadline_ms)}
  end

  defp cancel_start_timer(%{start_timer: nil} = state), do: state

  defp cancel_start_timer(state) do
    Process.cancel_timer(state.start_timer)
    %{state | start_timer: nil}
  end

  defp start_timers(state) do
    duration = max_duration_ms(state)

    %{
      state
      | max_duration_ms: duration,
        max_session_timer: Process.send_after(self(), :max_session_duration, duration)
    }
    |> schedule_usage_tick()
  end

  # The provider's own expiry wins when it is sooner: a session that expires in
  # four minutes cannot honour a fifteen-minute cap, and finding that out from a
  # dropped socket instead of a timer is how a call ends without accounting.
  defp max_duration_ms(state) do
    configured = state.config.max_session_minutes * @minute_ms

    case state.expires_at do
      expires when is_integer(expires) ->
        min(configured, max(0, (expires - state.unix_clock.()) * 1_000))

      _absent ->
        configured
    end
  end

  defp schedule_usage_tick(state) do
    %{state | usage_timer: Process.send_after(self(), :usage_tick, state.usage_tick_ms)}
  end

  defp cancel_timers(state) do
    Enum.each([state.start_timer, state.max_session_timer, state.usage_timer], &cancel_timer/1)

    %{
      cancel_reply_timer(state)
      | start_timer: nil,
        max_session_timer: nil,
        usage_timer: nil,
        tasks: CallTasks.cancel_timers(state.tasks)
    }
  end

  # Re-armed by every chunk of the reply, so it fires once the last of it has
  # had time to play. The token tells a stale expiry from the current one.
  defp arm_reply_timer(state, delay_ms) do
    state = cancel_reply_timer(state)
    token = make_ref()
    timer = Process.send_after(self(), {:reply_played_out, token}, delay_ms)
    %{state | reply_timer: {timer, token}}
  end

  defp cancel_reply_timer(%{reply_timer: nil} = state), do: state

  defp cancel_reply_timer(%{reply_timer: {timer, _token}} = state) do
    cancel_timer(timer)
    %{state | reply_timer: nil}
  end

  defp cancel_timer(nil), do: true
  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer) || true

  defp close_socket(%{live_pid: nil}), do: :ok

  defp close_socket(state) do
    state.live_client.close(state.live_pid)
    :ok
  rescue
    error -> Logger.debug("voice_live: socket close raised: #{inspect(error)}")
  catch
    kind, reason -> Logger.debug("voice_live: socket close exited: #{inspect({kind, reason})}")
  end

  defp enforce_ceiling(state) do
    if LiveLedger.over_ceiling?(state.ledger) do
      end_call(state, :cost_limit)
    else
      {:noreply, state}
    end
  end

  ## Telemetry and text shaping

  # The call's telemetry metadata, held by its tasks from here on: the
  # provider session id joins it once the session starts.
  defp telemetry_meta(config, call_id, call_uuid, device_id) do
    %{
      session_id: call_id,
      call_uuid: call_uuid,
      device_id: device_id,
      engine: config.engine,
      provider: config.provider,
      model: config.model,
      voice: config.voice,
      provider_session_id: nil
    }
  end

  defp call_measurements(state) do
    %{
      voice_seconds: LiveLedger.voice_seconds(state.ledger),
      voice_cost_millicents: LiveLedger.voice_cost_millicents(state.ledger),
      backend_turns: state.ledger.backend_turns,
      accounting_complete: if(state.ledger.accounting == :complete, do: 1, else: 0)
    }
  end

  defp provider_error_text(error) when is_map(error) do
    Map.get(error, "message") || Map.get(error, "type") || inspect(error)
  end

  defp require_binary(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_value, name), do: {:error, {:missing, name}}

  defp now(state), do: state.clock.()

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp unix_seconds, do: System.os_time(:second)
end
