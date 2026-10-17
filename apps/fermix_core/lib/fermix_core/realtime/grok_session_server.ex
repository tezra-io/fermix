defmodule FermixCore.Realtime.GrokSessionServer do
  @moduledoc """
  Owns one local full-duplex call on the Grok engine, `xai_realtime` (M70).

  Grok Voice 3.0 is the conversational frontend and Fermix does the work, as
  under GPT Live, but the two wires share nothing, so each has its own
  session owner and the tasks they hand off are one shared `CallTasks`.
  What this server owns follows from four facts about Grok's wire:

    * **One function, never a tool catalog.** The session registers exactly
      `fermix_task` (`GrokTaskCall`) and no hosted xAI tool. A call to it is a
      request for a Fermix task, answered with exactly one output when the
      task ends, and the task's request is built from the owner's own words
      on the call's transcript. The function stays open while the task runs,
      so the owner keeps talking to Grok meanwhile (M70 §04).
    * **Server VAD.** The owner's speech starts and ends Grok's responses by
      itself. `GrokTurn` is the one arbiter of the `response.create` that
      continues after a result, so one result is never answered twice.
    * **Playback the client reports.** Assistant audio is paced to the client
      under call-local playback ids (`GrokPlayback`, protocol v3); the client
      reports what it has played, which is what a barge-in truncates the
      assistant's item at and what tells a continuation it may speak. Audio
      sent and never acknowledged for `@ack_timeout_ms` ends the call.
    * **It bills by the session clock and the text item.** `GrokLedger` counts
      connected time (silence and mute included) and every billable text item
      at send; there is no vendor terminal usage, so the bill always settles
      `incomplete` with the local estimate.

  Nothing reconnects: a lost socket ends the call (resumption is off). Every
  terminal exit runs one settle path, as a Live call's does: the companion is
  told the call is idle, the tasks are cancelled or handed over to the chat,
  the socket is closed within `@close_deadline_ms`, the ledger is settled, the
  record closed, and `call_stop` telemetry carries WHY.

  Grok hears audio and permitted text only: what the call starts with and a
  message mirrored from the chat are masked against SpaceXAI's own Computer
  History grant (`LiveChat`), never OpenAI's.
  """

  use GenServer

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.ComputerHistory.Taint
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.BootstrapLoader
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.CallSpeech
  alias FermixCore.Realtime.CallTasks
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.ConversationRecorder
  alias FermixCore.Realtime.DeviceIdentity
  alias FermixCore.Realtime.GrokLatency
  alias FermixCore.Realtime.GrokLedger
  alias FermixCore.Realtime.GrokPlayback
  alias FermixCore.Realtime.GrokTaskCall
  alias FermixCore.Realtime.GrokTurn
  alias FermixCore.Realtime.LiveChat
  alias FermixCore.Realtime.LiveFrames
  alias FermixCore.Realtime.LivePrompt
  alias FermixCore.Realtime.LiveTelemetry
  alias FermixCore.Realtime.LiveText
  alias FermixCore.Realtime.LiveTranscript
  alias FermixCore.Realtime.VoiceBridge
  alias FermixCore.Realtime.XAIRealtimeClient
  alias FermixCore.Tools.Telemetry, as: ToolsTelemetry

  require Logger

  @minute_ms 60_000

  # Bounds the design fixes (M70 §05). All internal constants: the operator
  # configures a ceiling and a max duration, not a protocol.
  #
  # Connect, configure, the call's context acknowledged and the bridge open,
  # end to end, inside `SessionControl`'s 12-second `call_start`.
  @start_deadline_ms 10_000
  @close_deadline_ms 5_000
  @usage_tick_ms 5_000
  # Assistant audio the client was sent and never reported playing.
  @ack_timeout_ms 2_000
  # How long after the owner stops speaking Grok's own response may take to
  # start before a continuation owed is asked for.
  @vad_grace_ms 1_500
  # How long a requested continuation may take to start.
  @continuation_wait_ms 5_000
  # The documented Grok session maximum: a longer configured duration ends
  # the call here first.
  @provider_max_session_ms 120 * @minute_ms
  # Ten seconds of 24 kHz PCM16 held while the session starts; a start that
  # holds more has outlasted the start deadline, and fails.
  @max_held_audio_bytes 480_000
  # PCM16 at 24 kHz mono, for the local bounds of an assistant utterance.
  @bytes_per_ms 48
  # An assistant utterance's transcript, held until it is final.
  @max_assistant_text_bytes 8_192
  # What a call holds per utterance or response while it waits for the
  # provider's next word on it; the oldest goes first.
  @max_tracked 16
  # The events of handed-over tasks forwarded as this process exits.
  @max_forwarded 256

  # What a task's output tells Grok when Fermix has nothing of the task's own
  # to say.
  @insufficient_context "No words of the owner's were heard asking for this task; ask them to say it again."
  @submit_failed_line "Fermix could not start that task."
  @busy_line "Fermix is already working on a task and one more is waiting."

  @agent "voice_live"

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
  @spec socket_pid(GenServer.server()) :: pid() | nil
  def socket_pid(server), do: GenServer.call(server, :socket_pid)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.get_lazy(opts, :config, &Config.current/0)

    if config.engine == "xai_realtime" do
      claim_call(initial_state(opts, config))
    else
      {:stop, {:invalid_engine, config.engine}}
    end
  end

  # One call per daemon (M56 §4.8), whichever task engine holds it: the claim
  # is taken before this session exists to its caller, so a second
  # `call_start` is refused before it can open a session billed by the minute.
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
        Logger.info("voice_grok: refused a second call while one is in progress")
        {:stop, :call_in_progress}
    end
  end

  defp initial_state(opts, config) do
    clock = Keyword.get(opts, :clock, &monotonic_ms/0)
    call_id = to_string(Keyword.get(opts, :session_scope, "voice_live:unknown"))
    call_uuid = DeviceIdentity.generate_uuid()
    device_id = Keyword.get(opts, :device_id, "unknown")

    %{
      companion: Keyword.fetch!(opts, :companion),
      config: config,
      call_id: call_id,
      call_uuid: call_uuid,
      started_at: DateTime.utc_now(),
      started_ms: clock.(),
      call_registry: Keyword.get(opts, :call_registry, CallRegistry),
      api_key: Keyword.get(opts, :api_key),
      device_id: device_id,
      agent_id: Keyword.get(opts, :agent_id, MemoryConfig.agent_id()),
      client: Keyword.get(opts, :client, XAIRealtimeClient),
      socket: nil,
      voice_bridge: Keyword.get(opts, :voice_bridge),
      tasks:
        [
          call_id: call_id,
          call_uuid: call_uuid,
          conversation: Config.conversation(config),
          device_id: device_id,
          voice_provider: :xai,
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
      gist_opts: Keyword.get(opts, :gist, []),
      clock: clock,
      unix_clock: Keyword.get(opts, :unix_clock, &unix_seconds/0),
      start_deadline_ms: Keyword.get(opts, :start_deadline_ms, @start_deadline_ms),
      close_deadline_ms: Keyword.get(opts, :close_deadline_ms, @close_deadline_ms),
      usage_tick_ms: Keyword.get(opts, :usage_tick_ms, @usage_tick_ms),
      ack_timeout_ms: Keyword.get(opts, :ack_timeout_ms, @ack_timeout_ms),
      vad_grace_ms: Keyword.get(opts, :vad_grace_ms, @vad_grace_ms),
      continuation_wait_ms: Keyword.get(opts, :continuation_wait_ms, @continuation_wait_ms),
      # `:idle` until the socket opens, then `:connecting` (awaiting
      # `session.created`), `:configuring` (awaiting `session.updated`),
      # `:priming` (the call's context awaiting acknowledgement) and `:ready`.
      phase: :idle,
      # When the socket opened, on the call's clock: the provider's session
      # and its bill start there.
      connected_ms: nil,
      provider_session_id: nil,
      instructions: nil,
      context: [],
      # Billable items sent and not yet acknowledged, by client item id.
      unacked_items: MapSet.new(),
      # Why a start failed, in the vendor's or the daemon's own words.
      failure_detail: nil,
      max_duration_ms: min(config.max_session_minutes * @minute_ms, @provider_max_session_ms),
      muted?: false,
      speaking?: false,
      closing?: false,
      ledger: GrokLedger.new(config.max_estimated_cost_cents_per_session, clock.()),
      playback: GrokPlayback.new(),
      turn: GrokTurn.new(),
      transcript: LiveTranscript.new(),
      speech: CallSpeech.new(),
      # VAD bounds of the owner's utterances awaiting their transcript.
      user_items: %{},
      # The assistant's utterances in progress, by item id.
      assistant_items: %{},
      # Function calls awaiting their one output, and the call each task
      # answers.
      calls: %{},
      task_calls: %{},
      response_started_ms: %{},
      latency: GrokLatency.new(),
      held_audio: [],
      held_audio_bytes: 0,
      start_timer: nil,
      max_session_timer: nil,
      usage_timer: nil,
      ceiling_timer: nil,
      ack_timer: nil,
      vad_timer: nil,
      continuation_timer: nil
    }
  end

  ## Calls from the socket handler

  @impl true
  def handle_call(:call_start, _from, %{phase: :idle} = state) do
    case start_call(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:call_start, _from, state), do: {:reply, :ok, state}

  # An explicit interrupt stops every response in progress, flushes the
  # client's playback and truncates what was not heard. Work keeps running.
  def handle_call({:interrupt, _audio_end_ms}, _from, state) do
    state =
      state
      |> cancel_responses()
      |> barge_in()
      |> notify_state("listening")

    {:reply, :ok, state}
  end

  # Local only: Grok has no mute, so a muted call's microphone simply stops
  # at the daemon, and its session clock keeps running.
  def handle_call({:mute, enabled?}, _from, state) do
    {:reply, :ok,
     notify_state(%{state | muted?: enabled?}, if(enabled?, do: "muted", else: "listening"))}
  end

  def handle_call({:cancel_task, task_id}, _from, state) do
    case CallTasks.cancel(state.tasks, task_id, state.transcript) do
      {:ok, tasks, told} ->
        state = answer_task(%{state | tasks: tasks}, task_id, "cancelled", %{task_id: task_id})
        {:reply, :ok, tell(state, told)}

      {:error, :unknown_delegation} ->
        {:reply, {:error, :unknown_delegation}, state}
    end
  end

  def handle_call({:playback_progress, playback_id, played_ms, drained?}, _from, state) do
    case GrokPlayback.progress(state.playback, playback_id, played_ms, drained?) do
      {:ok, playback, forwards} ->
        state =
          %{state | playback: playback}
          |> played(played_ms)
          |> forward_audio(forwards)
          |> caption_heard()
          |> watch_playback()
          |> maybe_listening()
          |> maybe_continue()

        {:reply, :ok, state}

      {:error, reason} ->
        Logger.warning("voice_grok: refused a playback report: #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:call_stop, _from, state) do
    {:stop, {:shutdown, :call_stop}, :ok, settle(state, :call_stop)}
  end

  # The session's instructions, voice and tool are fixed when it is
  # configured; an edit applies to the next call.
  def handle_call(:reload_runtime, _from, state),
    do: {:reply, {:ok, %{tools: 1, applies: :next_call}}, state}

  def handle_call(:socket_pid, _from, state), do: {:reply, state.socket, state}

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
      :send -> {:noreply, send_provider(state, XAIRealtimeClient.audio_append_event(audio))}
      :hold -> hold_audio(state, audio)
      {:drop, reason} -> {:noreply, drop_audio(state, reason)}
    end
  end

  ## Messages

  @impl true
  def handle_info({:xai_realtime_event, pid, event}, %{socket: pid} = state),
    do: provider_event(event, state)

  def handle_info({:xai_realtime_error, pid, reason}, %{socket: pid} = state) do
    Logger.warning("voice_grok: provider frame unreadable: #{inspect(reason)}")
    LiveTelemetry.provider_error(state.tasks.meta, inspect(reason))
    {:noreply, state}
  end

  # A socket this session closed or abandoned: nothing it says is the call's.
  def handle_info({tag, pid, _message}, state)
      when tag in [:xai_realtime_event, :xai_realtime_error] and is_pid(pid) do
    Logger.debug("voice_grok: dropped #{tag} from #{inspect(pid)}, not the call's socket")
    {:noreply, state}
  end

  # The socket's death is the one liveness signal: nothing reconnects.
  def handle_info({:EXIT, pid, _reason}, %{socket: pid, closing?: true} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{socket: pid} = state) do
    Logger.warning("voice_grok: provider socket exited: #{inspect(reason)}")
    end_call(%{state | socket: nil}, :provider_disconnected)
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.debug("voice_grok: linked process #{inspect(pid)} exited: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(:start_deadline, %{phase: :ready} = state), do: {:noreply, state}

  def handle_info(:start_deadline, state) do
    Logger.warning("voice_grok: the session did not start within the start deadline")
    fail_start(state, "The voice session did not start in time.")
  end

  def handle_info(:max_session_duration, state), do: end_call(state, :max_session_duration)

  def handle_info(:usage_tick, state) do
    state = tick_ledger(state)
    notify_usage(state)
    enforce_ceiling(schedule_usage_tick(state))
  end

  def handle_info(:ceiling, state),
    do: enforce_ceiling(%{tick_ledger(state) | ceiling_timer: nil})

  # Stalled only when audio is still unreported and nothing more was heard
  # since the watch began: a client reporting the same offset again is not
  # playing.
  def handle_info({:ack_timeout, token}, %{ack_timer: {_timer, token, heard_ms}} = state) do
    state = %{state | ack_timer: nil}

    cond do
      not GrokPlayback.awaiting_ack?(state.playback) ->
        {:noreply, state}

      GrokPlayback.heard_ms(state.playback) == heard_ms ->
        Logger.warning("voice_grok: the client stopped reporting playback")
        end_call(state, :playback_stalled)

      true ->
        {:noreply, watch_playback(state)}
    end
  end

  def handle_info({:ack_timeout, _stale}, state), do: {:noreply, state}

  def handle_info({:vad_grace_over, token}, %{vad_timer: {_timer, token}} = state) do
    turn = GrokTurn.vad_grace_over(state.turn)
    {:noreply, maybe_continue(%{state | turn: turn, vad_timer: nil})}
  end

  def handle_info({:vad_grace_over, _stale}, state), do: {:noreply, state}

  def handle_info({:continuation_wait, id}, state) do
    if GrokTurn.requested(state.turn) == id,
      do:
        {:noreply, continuation_failed(%{state | continuation_timer: nil}, "not started in time")},
      else: {:noreply, state}
  end

  def handle_info({:context_wait_expired, task_id, revision}, state) do
    {tasks, told} =
      CallTasks.context_wait_expired(state.tasks, task_id, revision, state.transcript)

    {:noreply, tell(%{state | tasks: tasks}, told)}
  end

  def handle_info({:delegation_event, task_id, revision, event}, state) do
    {tasks, told} =
      CallTasks.delegation_event(state.tasks, task_id, revision, event, state.transcript)

    {:noreply, tell(%{state | tasks: tasks}, told)}
  end

  # A confirmed access-sensitive command finished, or crashed.
  def handle_info({ref, _outcome} = message, state) when is_reference(ref),
    do: access_message(message, state)

  def handle_info({:DOWN, ref, :process, _pid, _reason} = message, state) when is_reference(ref),
    do: access_message(message, state)

  def handle_info(message, state) do
    Logger.debug("voice_grok: unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{companion: _companion} = state) do
    state = cancel_timers(state)
    tasks = CallTasks.close_bridge_call(state.tasks)
    CallTasks.forward_detached(tasks, @max_forwarded)
    kill_socket(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Call start

  # The person may speak from the moment the call is accepted: what they say
  # is held until the session is ready and then passed on in order.
  # The start deadline is armed first, so the handshake counts against it; a
  # start that fails here cancels it, the call never having opened.
  defp start_call(state) do
    state = state |> notify_state("listening") |> arm_start_deadline()

    with {:ok, bridge} <- resolve_bridge(state),
         {:ok, instructions} <- resolve_prompt(state),
         {:ok, {context, tainted?}} <- resolve_context(state, bridge),
         {:ok, api_key} <- require_binary(state.api_key, :api_key),
         {:ok, socket} <- open_socket(state, api_key) do
      tasks = state.tasks |> CallTasks.put_bridge(bridge) |> taint_if(tainted?)

      state = %{
        state
        | voice_bridge: bridge,
          socket: socket,
          tasks: tasks,
          instructions: instructions,
          context: context,
          phase: :connecting,
          connected_ms: now(state),
          # Billed from the connection, so the ledger starts with it.
          ledger: GrokLedger.new(state.config.max_estimated_cost_cents_per_session, now(state))
      }

      LiveTelemetry.call_start(
        state.tasks.meta,
        state.max_duration_ms,
        Map.put(LiveChat.context_size(context), :instructions_bytes, byte_size(instructions))
      )

      {:ok, open_record(state)}
    else
      {:error, {:provider_refused, reason}} -> refuse_start(cancel_start_timer(state), reason)
      {:error, reason} -> {:error, reason, notify_error(cancel_start_timer(state), reason, nil)}
    end
  end

  # The handshake was refused (a 401 for a missing or revoked key is the
  # common one): the vendor's own sentence reaches the trace and the
  # companion before the caller is answered.
  defp refuse_start(state, reason) do
    detail = LiveText.reason(reason)
    Logger.warning("voice_grok: the provider refused the session: #{detail}")
    LiveTelemetry.provider_error(state.tasks.meta, detail)
    {:error, :provider_refused, notify_error(state, :provider_refused, detail)}
  end

  defp resolve_bridge(%{voice_bridge: module}) when is_atom(module) and not is_nil(module),
    do: {:ok, module}

  defp resolve_bridge(_state), do: VoiceBridge.resolve()

  defp resolve_prompt(%{prompt: prompt}) when is_binary(prompt), do: {:ok, prompt}

  # GROK.md, then the same identity, date, memory and capability facts a Live
  # call is told (M70 §07).
  defp resolve_prompt(state) do
    conversation = Config.conversation(state.config)

    with {:ok, grok_md} <- BootstrapLoader.load_grok(state.agent_id),
         {:ok, context} <- LivePrompt.context(state.agent_id, conversation) do
      capabilities = LivePrompt.eligible_capabilities(state.capability_registry, conversation)
      {:ok, LivePrompt.compose(grok_md.content, capabilities, context)}
    end
  end

  # A call in the chat's conversation starts with the chat, masked against
  # SpaceXAI's own grant; a private call reads none of it.
  defp resolve_context(state, bridge) do
    case Config.conversation(state.config) do
      "chat" -> chat_context(bridge)
      "private" -> {:ok, {[], false}}
    end
  end

  defp chat_context(bridge) do
    with {:ok, window} <- bridge.conversation_window(LiveChat.window_bounds()) do
      {:ok, {LiveChat.context(window, :xai), LiveChat.carries_taint?(window, :xai)}}
    end
  end

  defp open_socket(state, api_key) do
    case state.client.start_link(
           url: XAIRealtimeClient.url(state.config.model),
           headers: XAIRealtimeClient.headers(api_key),
           parent: self()
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:provider_refused, reason}}
    end
  end

  # The session is configured once, on the event the provider opens it with.
  defp configure(state, session_id) do
    tasks = CallTasks.put_meta(state.tasks, %{provider_session_id: session_id})

    event =
      XAIRealtimeClient.session_update_event(state.config, state.instructions, [
        GrokTaskCall.tool()
      ])

    state = %{state | provider_session_id: session_id, tasks: tasks, phase: :configuring}
    {:noreply, send_provider(state, event)}
  end

  # The provider applied the configuration. A turn detection other than the
  # server VAD this session is built on is a session it cannot run.
  defp configured(state, %{turn_detection: detection}) when detection in [nil, "server_vad"] do
    state = prime(state)

    if MapSet.size(state.unacked_items) == 0,
      do: become_ready(state),
      else: {:noreply, %{state | phase: :priming}}
  end

  defp configured(state, %{turn_detection: detection}),
    do: fail_start(state, "The provider configured turn detection #{inspect(detection)}.")

  # The call's context, one acknowledged item per line: quoted, never a
  # request, and never answered (no `response.create` follows).
  defp prime(state) do
    Enum.reduce(state.context, %{state | context: []}, fn entry, acc ->
      send_billable_item(acc, context_role(entry.role), entry.text)
    end)
  end

  defp context_role(:context), do: "system"
  defp context_role(:user), do: "user"
  defp context_role(:assistant), do: "assistant"

  defp become_ready(state) do
    state = cancel_start_timer(state)

    case CallTasks.open_bridge_call(state.tasks) do
      {:ok, tasks} ->
        state = %{state | tasks: tasks, phase: :ready}
        LiveTelemetry.session_started(state.tasks.meta)
        {:noreply, state |> start_timers() |> notify_call_ready() |> release_held_audio()}

      {:error, reason} ->
        Logger.error("voice_grok: the voice bridge refused the call: #{inspect(reason)}")
        end_call(state, :bridge_unavailable)
    end
  end

  # A start that failed after the call was accepted: the vendor's or the
  # daemon's own sentence rides the call's one error frame.
  defp fail_start(state, detail) do
    LiveTelemetry.provider_error(state.tasks.meta, detail)
    end_call(%{state | failure_detail: detail}, :provider_refused)
  end

  ## Provider events

  defp provider_event({:session_created, id}, %{phase: :connecting} = state),
    do: configure(state, id)

  defp provider_event({:session_updated, info}, %{phase: :configuring} = state),
    do: configured(state, info)

  defp provider_event({:item_added, %{id: id}}, state), do: item_added(state, id)

  defp provider_event({:speech_started, item_id}, state),
    do: {:noreply, speech_started(state, item_id)}

  defp provider_event({:speech_stopped, item_id}, state),
    do: {:noreply, speech_stopped(state, item_id)}

  defp provider_event({:user_transcript, item_id, transcript}, state),
    do: {:noreply, user_transcript(state, item_id, transcript)}

  defp provider_event({:response_created, response_id, metadata}, state),
    do: {:noreply, response_created(state, response_id, metadata)}

  defp provider_event({:audio_delta, response_id, item_id, content_index, audio}, state),
    do: assistant_audio(state, response_id, item_id, content_index, audio)

  defp provider_event({:assistant_transcript_delta, response_id, item_id, delta}, state),
    do: {:noreply, assistant_words(state, response_id, item_id, delta)}

  defp provider_event({:assistant_transcript_done, _response_id, item_id}, state),
    do: {:noreply, assistant_said(state, item_id)}

  defp provider_event({:item_truncated, item_id, transcript}, state),
    do: {:noreply, assistant_truncated(state, item_id, transcript)}

  defp provider_event({:function_call, call}, state), do: function_call(state, call)

  defp provider_event({:response_done, response_id, status, usage}, state),
    do: {:noreply, response_done(state, response_id, status, usage)}

  # Before the session is ready any error is about its configuration or its
  # context, and the call cannot start on half of either.
  defp provider_event({:error, error}, %{phase: phase} = state) when phase != :ready,
    do: fail_start(state, provider_error_text(error))

  # Not terminal: most provider errors leave the session as it was. An error
  # names no client event Fermix can match (its events carry no id), so a
  # refused continuation is found by its own wait, never guessed from here.
  defp provider_event({:error, error}, state) do
    text = provider_error_text(error)
    Logger.warning("voice_grok: provider error: #{text}")
    LiveTelemetry.provider_error(state.tasks.meta, text)
    {:noreply, state}
  end

  defp provider_event({:unhandled, type}, state) do
    Logger.debug("voice_grok: unhandled provider event #{type}")
    {:noreply, state}
  end

  defp provider_event(event, state) do
    Logger.debug("voice_grok: provider event out of turn: #{inspect(elem(event, 0))}")
    {:noreply, state}
  end

  defp item_added(state, id) do
    if MapSet.member?(state.unacked_items, id) do
      state = %{
        state
        | unacked_items: MapSet.delete(state.unacked_items, id),
          ledger: GrokLedger.text_item_acked(state.ledger)
      }

      primed(state)
    else
      {:noreply, state}
    end
  end

  defp primed(%{phase: :priming} = state) do
    if MapSet.size(state.unacked_items) == 0, do: become_ready(state), else: {:noreply, state}
  end

  defp primed(state), do: {:noreply, state}

  ## The owner's turn

  # Speech over a reply that is still playing is a barge-in: the client's
  # playback is flushed and what was not heard is cut from Grok's context.
  # Server VAD stops Grok's response itself. Work keeps running.
  defp speech_started(state, item_id) do
    state = %{
      state
      | turn: GrokTurn.speech_started(state.turn),
        user_items: put_bounded(state.user_items, item_id, {offset_ms(state), nil}, &elem(&1, 0))
    }

    state = if GrokPlayback.drained?(state.playback), do: state, else: barge_in(state)
    notify_state(state, "listening")
  end

  defp speech_stopped(state, item_id) do
    {start_ms, _end_ms} = Map.get(state.user_items, item_id, {offset_ms(state), nil})

    user_items =
      put_bounded(state.user_items, item_id, {start_ms, offset_ms(state)}, &elem(&1, 0))

    %{
      state
      | turn: GrokTurn.speech_stopped(state.turn),
        user_items: user_items,
        latency: GrokLatency.speech_ended(state.latency, now(state))
    }
    |> notify_state("thinking")
    |> arm_vad_timer()
  end

  # One finalized utterance, once: the transcript the task request reads, the
  # call's speech, a caption and, when kept, the record. Its bounds are the
  # local moments VAD heard it start and stop, not word alignment.
  defp user_transcript(state, item_id, transcript) do
    {{start_ms, end_ms}, user_items} = pop_bounds(state.user_items, item_id, offset_ms(state))
    state = %{state | user_items: user_items}

    case String.trim(transcript) do
      "" -> state
      _words -> utterance(state, :user, transcript, start_ms, end_ms)
    end
  end

  defp pop_bounds(user_items, item_id, now_ms) do
    case Map.pop(user_items, item_id) do
      {{start_ms, nil}, rest} -> {{start_ms, now_ms}, rest}
      {{start_ms, end_ms}, rest} -> {{start_ms, end_ms}, rest}
      {nil, rest} -> {{now_ms, now_ms}, rest}
    end
  end

  defp utterance(state, speaker, text, start_ms, end_ms) do
    state = %{
      state
      | transcript: LiveTranscript.append(state.transcript, speaker, text, start_ms, end_ms),
        speech: keep_speech(state, speaker, text)
    }

    notify(state, LiveFrames.caption(Atom.to_string(speaker), text, start_ms, end_ms))
    record_caption(state, speaker, text, start_ms, end_ms)
    state
  end

  # A private call keeps only the task window, as a Live call does (M56 §5).
  defp keep_speech(state, speaker, text) do
    case Config.conversation(state.config) do
      "chat" -> CallSpeech.append(state.speech, speaker, text)
      "private" -> state.speech
    end
  end

  ## Grok's responses

  # Any response that starts hears what was asked of it: Fermix's own
  # continuation, or one Grok started that consumed it (`GrokTurn`).
  defp response_created(state, response_id, metadata) do
    started = put_bounded(state.response_started_ms, response_id, now(state), & &1)

    %{
      state
      | turn: GrokTurn.response_created(state.turn, response_id, metadata),
        response_started_ms: started,
        latency: latency_on_response(state.latency, metadata)
    }
    |> cancel_vad_timer()
    |> cancel_continuation_timer()
  end

  # A reply Fermix asked for answers a result, not the owner's last turn.
  defp latency_on_response(latency, %{"fermix_continuation" => _id}),
    do: GrokLatency.continuation_started(latency)

  defp latency_on_response(latency, _metadata), do: latency

  defp assistant_audio(state, response_id, item_id, content_index, audio) do
    if GrokTurn.fenced?(state.turn, response_id) do
      {:noreply, state}
    else
      case GrokPlayback.audio(state.playback, response_id, item_id, content_index, audio) do
        {:ok, playback, forwards} ->
          state = %{state | playback: playback} |> note_assistant_audio(item_id, audio)
          {:noreply, state |> forward_audio(forwards) |> watch_playback()}

        {:error, :overflow} ->
          end_call(state, :playback_overflow)

        {:error, :invalid_audio} ->
          LiveTelemetry.provider_error(state.tasks.meta, "invalid audio delta")
          {:noreply, state}
      end
    end
  end

  # When an assistant utterance began on the call's clock, and how much of it
  # there is, for the local bounds of its caption.
  defp note_assistant_audio(state, item_id, audio) do
    bytes = div(byte_size(audio) * 3, 4)

    item =
      state.assistant_items
      |> Map.get(item_id, assistant_item(offset_ms(state)))
      |> Map.update!(:bytes, &(&1 + bytes))

    %{state | assistant_items: put_assistant_item(state, item_id, item)}
  end

  defp assistant_item(start_ms),
    do: %{start_ms: start_ms, bytes: 0, text: "", done?: false, truncating?: false}

  defp put_assistant_item(state, item_id, item),
    do: put_bounded(state.assistant_items, item_id, item, & &1.start_ms)

  # Words of an interrupted response were never heard, so they never reach a
  # caption or the transcript a task reads.
  defp assistant_words(state, response_id, item_id, delta) do
    if GrokTurn.fenced?(state.turn, response_id) do
      state
    else
      item =
        state.assistant_items
        |> Map.get(item_id, assistant_item(offset_ms(state)))
        |> Map.update!(:text, &bounded_text(&1 <> delta))

      %{state | assistant_items: put_assistant_item(state, item_id, item)}
    end
  end

  # The words are final; the caption waits until they have been heard.
  defp assistant_said(state, item_id) do
    case Map.get(state.assistant_items, item_id) do
      nil ->
        state

      item ->
        caption_heard(%{
          state
          | assistant_items: Map.put(state.assistant_items, item_id, %{item | done?: true})
        })
    end
  end

  # Each finished utterance is captioned once, when the owner has heard all
  # of it that reached them, oldest first. One a barge-in cut waits for the
  # provider's own record of what remains (`assistant_truncated/3`).
  defp caption_heard(state) do
    state.assistant_items
    |> Enum.filter(fn {item_id, item} ->
      item.done? and not item.truncating? and GrokPlayback.heard?(state.playback, item_id)
    end)
    |> Enum.sort_by(fn {_item_id, item} -> item.start_ms end)
    |> Enum.reduce(state, fn {item_id, item}, acc ->
      assistant_utterance(acc, item_id, item.text)
    end)
  end

  defp assistant_truncated(state, item_id, transcript) do
    case Map.get(state.assistant_items, item_id) do
      nil -> state
      _item -> assistant_utterance(state, item_id, transcript || "")
    end
  end

  defp assistant_utterance(state, item_id, text) do
    {item, items} = Map.pop(state.assistant_items, item_id)
    state = %{state | assistant_items: items}
    end_ms = item.start_ms + div(item.bytes, @bytes_per_ms)

    case String.trim(text) do
      "" -> state
      _words -> utterance(state, :assistant, text, item.start_ms, end_ms)
    end
  end

  defp response_done(state, response_id, status, usage) do
    {started_ms, started} = Map.pop(state.response_started_ms, response_id)
    emit_provider_call(state, status, usage, started_ms)

    %{state | turn: GrokTurn.response_done(state.turn, response_id), response_started_ms: started}
    |> maybe_listening()
    |> maybe_continue()
  end

  # One provider call per response, with the vendor's own token counts when it
  # sent them: never a fabricated count, and never the transcripts.
  defp emit_provider_call(state, status, usage, started_ms) do
    ProviderTelemetry.emit_call(
      %{
        provider: :xai,
        model: state.config.model,
        # A response cut short by the owner speaking is the wire working, not
        # a provider failure.
        status: if(status in ["completed", "cancelled"], do: :ok, else: :error),
        agent: @agent,
        tokens: tokens(usage)
      },
      max(0, now(state) - (started_ms || now(state))),
      session_id: state.call_id
    )
  end

  defp tokens(%{} = usage) do
    prompt = count(Map.get(usage, "input_tokens"))
    completion = count(Map.get(usage, "output_tokens"))
    %{prompt: prompt, completion: completion, total: prompt + completion}
  end

  defp tokens(nil), do: %{}

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_absent), do: 0

  ## Function calls

  defp function_call(state, %{response_id: response_id, call_id: call_id} = call) do
    case GrokTurn.function_call(state.turn, response_id, call_id) do
      {:duplicate, _turn} ->
        Logger.debug("voice_grok: ignored a repeated function call #{call_id}")
        {:noreply, state}

      {:exhausted, turn} ->
        Logger.error("voice_grok: the call remembers no more function call ids")
        end_call(%{state | turn: turn}, :call_ids_exhausted)

      {:too_many, turn} ->
        state = open_call(%{state | turn: turn}, call_id, parse_call(call))
        {:noreply, reject(state, call_id, "too_many_calls")}

      {:ok, turn} ->
        parsed = parse_call(call)
        {:noreply, run_call(open_call(%{state | turn: turn}, call_id, parsed), call, parsed)}
    end
  end

  defp parse_call(%{name: name, arguments: arguments}) do
    if name == GrokTaskCall.name(),
      do: GrokTaskCall.parse(arguments),
      else: {:error, :unknown_function}
  end

  defp open_call(state, call_id, parsed) do
    entry = %{started_ms: now(state), action: action_name(parsed)}
    %{state | calls: Map.put(state.calls, call_id, entry)}
  end

  defp action_name({:ok, {:submit, _request, _task_id}}), do: "submit"
  defp action_name({:ok, {:cancel, _task_id}}), do: "cancel"
  defp action_name({:error, _refusal}), do: "invalid"

  # Interrupting Grok stops its audio, never the owner's request (M70 §04):
  # a call its response carried is run, however that response ended.
  defp run_call(state, %{call_id: call_id}, parsed), do: act(state, call_id, parsed)

  # A task's id is Fermix's own and unique on this daemon, never a count per
  # call: a task of an earlier call may still run in the chat's queue, under
  # its id, after that call ended.
  defp act(state, call_id, {:ok, {:submit, request, nil}}) do
    task_id = "t" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    state = %{state | task_calls: Map.put(state.task_calls, task_id, call_id)}

    {_admitted, tasks, told} =
      CallTasks.create(
        state.tasks,
        task_id,
        offset_ms(state),
        state.transcript,
        ask(state, request)
      )

    tell(%{state | tasks: tasks}, told)
  end

  # A task asked for again in new words takes its next revision; the call that
  # asked for the earlier one is answered `superseded`. Only the owner changes
  # a task: a replacement with no word of theirs since the task began is
  # refused.
  defp act(state, call_id, {:ok, {:submit, request, task_id}}) do
    with :ok <- owner_spoke_since_task(state, task_id),
         {:ok, tasks, told} <-
           CallTasks.revise(
             state.tasks,
             task_id,
             offset_ms(state),
             state.transcript,
             ask(state, request)
           ) do
      {earlier, task_calls} = Map.pop(state.task_calls, task_id)

      %{state | tasks: tasks, task_calls: Map.put(task_calls, task_id, call_id)}
      |> answer(earlier, "superseded", %{task_id: task_id})
      |> tell(told)
    else
      {:error, reason} -> reject(state, call_id, refusal(reason))
    end
  end

  # As with a replacement, a cancellation needs the owner's own words since
  # the task began.
  defp act(state, call_id, {:ok, {:cancel, task_id}}) do
    with :ok <- owner_spoke_since_task(state, task_id),
         {:ok, tasks, told} <- CallTasks.cancel(state.tasks, task_id, state.transcript) do
      %{state | tasks: tasks}
      |> answer_task(task_id, "cancelled", %{task_id: task_id})
      |> answer(call_id, "cancelled", %{task_id: task_id})
      |> tell(told)
    else
      {:error, reason} -> reject(state, call_id, refusal(reason))
    end
  end

  defp act(state, call_id, {:error, refusal}), do: reject(state, call_id, Atom.to_string(refusal))

  # What the voice model said the task was, and whether the owner's latest
  # words are still being transcribed: then the task waits for them, so it
  # never runs on the paraphrase alone (M70 §04).
  defp ask(state, request),
    do: [voice_request: request, await_words: words_pending?(state)]

  defp words_pending?(state), do: map_size(state.user_items) > 0

  # The owner spoke after the task's current revision began: words heard
  # since, or speech VAD heard start since whose words are on their way.
  defp owner_spoke_since_task(state, task_id) do
    case CallTasks.fetch(state.tasks, task_id) do
      {:ok, record} ->
        if spoke_since?(state, record.offset_ms), do: :ok, else: {:error, :no_owner_words}

      :error ->
        {:error, :unknown_delegation}
    end
  end

  defp spoke_since?(state, offset_ms) do
    LiveTranscript.user_text_since(state.transcript, offset_ms) != "" or
      Enum.any?(state.user_items, fn {_item_id, {start_ms, _end_ms}} -> start_ms > offset_ms end)
  end

  defp refusal(:unknown_delegation), do: "unknown_task"
  defp refusal(:no_owner_words), do: "no_owner_words"

  defp reject(state, call_id, reason), do: answer(state, call_id, "rejected", %{reason: reason})

  ## What the call's tasks tell Grok

  # Each result is the output of the call that asked for it, as data; progress
  # stays on the task frames (M70 §04: no synthetic spoken progress).
  defp tell(state, told), do: Enum.reduce(told, state, &say/2)

  defp say({:clarify, record}, state),
    do:
      answer_task(state, record.id, "failed", %{
        task_id: record.id,
        reason: "insufficient_context",
        message: @insufficient_context
      })

  defp say({:submit_failed, record}, state),
    do:
      answer_task(state, record.id, "failed", %{task_id: record.id, message: @submit_failed_line})

  defp say({:progress, _record, _text}, state), do: state
  defp say({:tool_started, _record, _name}, state), do: state

  # A completed task is a backend turn the ledger counts, never prices.
  defp say({:completed, record, spoken}, state) do
    %{state | ledger: GrokLedger.record_backend_turn(state.ledger)}
    |> answer_task(record.id, "completed", %{task_id: record.id, result: spoken})
  end

  defp say({:cancelled, record}, state),
    do: answer_task(state, record.id, "cancelled", %{task_id: record.id})

  defp say({:failed, record, sentence}, state),
    do: answer_task(state, record.id, "failed", %{task_id: record.id, message: sentence})

  defp say({:busy, task_id}, state),
    do: answer_task(state, task_id, "busy", %{message: @busy_line})

  # The call is ending: nothing more is said to Grok.
  defp say(:handed_over, state), do: state

  defp say({:frame, frame}, state) do
    notify(state, frame)
    state
  end

  defp answer_task(state, task_id, status, fields) do
    {call_id, task_calls} = Map.pop(state.task_calls, task_id)
    answer(%{state | task_calls: task_calls}, call_id, status, fields)
  end

  # A call's one output. The tool event closes the call in the trace under
  # the name the model used, whatever became of it.
  defp answer(state, nil, _status, _fields), do: state

  defp answer(state, call_id, status, fields) do
    {call, calls} = Map.pop(state.calls, call_id)
    output = GrokTaskCall.output(status, fields)

    event =
      XAIRealtimeClient.function_output_event(XAIRealtimeClient.new_item_id(), call_id, output)

    emit_tool(state, call, status, Map.get(fields, :task_id))

    %{state | calls: calls, turn: GrokTurn.answered(state.turn, call_id)}
    |> send_provider(event)
    |> maybe_continue()
  end

  defp emit_tool(state, call, status, task_id) do
    ToolsTelemetry.exec(
      GrokTaskCall.name(),
      %{agent_name: @agent, session_id: state.call_id},
      status in ["completed", "cancelled", "superseded"],
      max(0, now(state) - call.started_ms),
      metadata: %{status: status, task_id: task_id, action: call.action}
    )
  end

  defp access_message(message, state) do
    case CallTasks.access_message(state.tasks, message, state.transcript) do
      {:ok, tasks, told} ->
        {:noreply, tell(%{state | tasks: tasks}, told)}

      :unknown ->
        Logger.debug("voice_grok: unexpected message #{inspect(message)}")
        {:noreply, state}
    end
  end

  ## The continuation

  # The one place `response.create` is sent (`GrokTurn.due?/2`).
  defp maybe_continue(%{phase: :ready, closing?: false} = state) do
    if GrokTurn.due?(state.turn, GrokPlayback.drained?(state.playback)) do
      {id, turn} = GrokTurn.request(state.turn)

      %{state | turn: turn}
      |> send_provider(XAIRealtimeClient.response_create_event(id))
      |> arm_continuation_timer(id)
    else
      state
    end
  end

  defp maybe_continue(state), do: state

  defp continuation_failed(state, why) do
    case GrokTurn.request_failed(state.turn) do
      {:retry, turn} ->
        Logger.info("voice_grok: a continuation was #{why}; it is owed again")
        maybe_continue(cancel_continuation_timer(%{state | turn: turn}))

      {:gave_up, turn} ->
        Logger.warning(
          "voice_grok: a continuation was #{why} twice; the result stays in the task frame"
        )

        LiveTelemetry.provider_error(state.tasks.meta, "continuation #{why}")
        cancel_continuation_timer(%{state | turn: turn})

      {:none, _turn} ->
        state
    end
  end

  ## Interruptions and playback

  defp cancel_responses(state) do
    Enum.reduce(GrokTurn.cancellable(state.turn), state, fn response_id, acc ->
      %{acc | turn: GrokTurn.fence(acc.turn, response_id)}
      |> send_provider(XAIRealtimeClient.response_cancel_event(response_id))
    end)
  end

  # The client's playback is flushed, every response in progress is fenced so
  # its later audio is dropped, and each utterance is cut where it was heard.
  defp barge_in(state) do
    {playback, targets} = GrokPlayback.stop(state.playback)
    notify(state, LiveFrames.playback_stop())

    turn = Enum.reduce(GrokTurn.active(state.turn), state.turn, &GrokTurn.fence(&2, &1))
    state = cancel_ack_timer(%{state | playback: playback, turn: turn})

    Enum.reduce(targets, state, &truncate/2)
  end

  # An utterance already captioned was heard whole and has no entry left to
  # mark; its truncation only trims Grok's context.
  defp truncate(%{item_id: item_id, content_index: index, played_ms: played_ms}, state) do
    items =
      case Map.fetch(state.assistant_items, item_id) do
        {:ok, item} -> Map.put(state.assistant_items, item_id, %{item | truncating?: true})
        :error -> state.assistant_items
      end

    %{state | assistant_items: items}
    |> send_provider(XAIRealtimeClient.truncate_event(item_id, index, played_ms))
  end

  defp forward_audio(state, []), do: state

  defp forward_audio(state, forwards) do
    state = if state.speaking?, do: state, else: notify_state(state, "speaking")
    state = %{state | latency: GrokLatency.audio_forwarded(state.latency, now(state))}

    Enum.each(forwards, fn {playback_id, audio} ->
      notify(state, LiveFrames.audio_delta(audio, playback_id))
    end)

    state
  end

  defp played(state, 0), do: state

  defp played(state, _played_ms),
    do: %{state | latency: GrokLatency.audio_played(state.latency, now(state))}

  # The reply has played out once the client drained it and nothing is being
  # generated.
  defp maybe_listening(%{speaking?: true} = state) do
    if GrokPlayback.drained?(state.playback) and GrokTurn.cancellable(state.turn) == [],
      do: notify_state(state, "listening"),
      else: state
  end

  defp maybe_listening(state), do: state

  ## The chat, mirrored

  # M56 §4.3 on Grok's wire: a line the owner typed, or the chat's answer, as
  # one quiet `system` item, never followed by `response.create`, only while a
  # call in the chat is up and its budget still affords a text item.
  defp mirror_chat(state, event) do
    case mirror_line(state, event) do
      {:ok, line} ->
        state |> send_billable_item("system", line) |> mirrored_taint(event)

      {:drop, why} ->
        Logger.debug("voice_grok: a chat #{elem(event, 0)} message was not mirrored (#{why})")
        state
    end
  end

  defp mirror_line(%{phase: :ready, closing?: false} = state, event) do
    cond do
      Config.conversation(state.config) != "chat" -> {:drop, :private}
      not GrokLedger.affords_text_item?(state.ledger) -> {:drop, :budget}
      true -> chat_line(event)
    end
  end

  defp mirror_line(_state, _event), do: {:drop, :not_ready}

  defp chat_line(event) do
    case LiveChat.mirror_line(event, :xai) do
      {:ok, line} -> {:ok, line}
      :drop -> {:drop, :withheld}
    end
  end

  defp mirrored_taint(state, {:answered, message}),
    do: %{state | tasks: taint_if(state.tasks, Taint.tainted?(message))}

  defp mirrored_taint(state, {:typed, _text}), do: state

  # A text item is a possible charge from the moment it is sent, so it is
  # counted then, and the ceiling's deadline moves closer.
  defp send_billable_item(state, role, text) do
    if GrokLedger.affords_text_item?(state.ledger) do
      id = XAIRealtimeClient.new_item_id()

      %{
        state
        | ledger: GrokLedger.text_item_sent(state.ledger),
          unacked_items: MapSet.put(state.unacked_items, id)
      }
      |> send_provider(XAIRealtimeClient.context_item_event(id, role, text))
      |> arm_ceiling_timer()
    else
      Logger.warning("voice_grok: a #{role} item was not sent: the call's budget is spent")
      state
    end
  end

  defp taint_if(tasks, true), do: CallTasks.mark_tainted(tasks)
  defp taint_if(tasks, false), do: tasks

  ## Teardown

  defp end_call(state, reason), do: {:stop, {:shutdown, reason}, settle(state, reason)}

  # THE terminal path, in the order a Live call settles.
  defp settle(%{closing?: true} = state, _reason), do: state

  defp settle(state, reason) do
    state =
      %{state | closing?: true}
      |> notify_state("idle")
      |> notify_terminal(reason)
      |> leave_tasks()

    state = %{state | tasks: CallTasks.close_bridge_call(state.tasks)} |> close_open_calls()
    state = close_socket(state)
    state = %{state | ledger: GrokLedger.finalize(state.ledger, now(state))}

    ending = ending(state, reason)
    owes = CallTasks.close_record(state.tasks, ending)
    notify_usage(state)
    LiveTelemetry.call_stop(state.tasks.meta, call_measurements(state), reason)
    CallTasks.leave_for_chat(state.tasks, ending, owes)
    cancel_timers(state)
  end

  defp notify_terminal(state, :call_stop), do: state

  defp notify_terminal(state, :cost_limit) do
    notify_usage(state, "limit_reached")
    notify_error(state, :cost_limit, nil)
  end

  defp notify_terminal(state, reason), do: notify_error(state, reason, state.failure_detail)

  defp leave_tasks(state) do
    {tasks, told} = CallTasks.leave(state.tasks, state.transcript)
    tell(%{state | tasks: tasks}, told)
  end

  # A call still open as the session closes never gets its output: the
  # session is going. The trace still closes it, once.
  defp close_open_calls(state) do
    Enum.each(state.calls, fn {_call_id, call} -> emit_tool(state, call, "call_ended", nil) end)
    %{state | calls: %{}, task_calls: %{}}
  end

  # The close is sent once and the socket's exit awaited, at most
  # `close_deadline_ms`; a socket that does not go is killed. Selective, so the
  # audio still in the mailbox is left alone.
  defp close_socket(%{socket: nil} = state), do: state

  defp close_socket(%{socket: socket} = state) do
    state.client.close(socket)

    receive do
      {:EXIT, ^socket, _reason} -> :ok
    after
      state.close_deadline_ms ->
        Logger.warning("voice_grok: the provider socket did not close in time; it is killed")
        Process.exit(socket, :kill)
    end

    %{state | socket: nil}
  end

  defp kill_socket(%{socket: socket}) when is_pid(socket), do: Process.exit(socket, :kill)
  defp kill_socket(_state), do: :ok

  defp ending(state, reason) do
    %{
      reason: reason,
      usage: GrokLedger.usage_payload(state.ledger),
      speech: state.speech,
      started_at: state.started_at,
      # Only a call that became ready ever had a conversation to leave.
      provider_started?: state.phase == :ready,
      gist_opts: state.gist_opts
    }
  end

  # The bill, then how long the owner waited (`GrokLatency`).
  defp call_measurements(state) do
    Map.merge(
      %{
        voice_seconds: GrokLedger.connected_ms(state.ledger) / 1_000,
        voice_cost_millicents: GrokLedger.voice_cost_millicents(state.ledger),
        voice_text_items: state.ledger.text_items_sent,
        backend_turns: state.ledger.backend_turns,
        accounting_complete: 0
      },
      GrokLatency.measurements(state.latency)
    )
  end

  ## Companion frames

  defp notify(%{companion: companion}, frame) when is_pid(companion) do
    send(companion, {:realtime, frame})
    :ok
  end

  defp notify_state(state, value) do
    notify(state, LiveFrames.state(value))
    %{state | speaking?: value == "speaking"}
  end

  # `expires_at` is whichever limit ends the call first, as things stand when
  # it is ready: the configured duration or Grok's own maximum, counted from
  # the connection, or the budget at the session clock's rate.
  defp notify_call_ready(state) do
    ends_in_ms = min(remaining_ms(state), GrokLedger.ms_until_ceiling(tick_ledger(state).ledger))

    notify(
      state,
      LiveFrames.call_ready(
        state.config.engine,
        state.call_id,
        state.call_uuid,
        Config.conversation(state.config),
        state.provider_session_id,
        state.unix_clock.() + div(ends_in_ms, 1_000)
      )
    )

    notify_state(state, "listening")
  end

  defp notify_usage(state, status \\ nil) do
    notify(
      state,
      LiveFrames.usage(state.call_uuid, GrokLedger.usage_payload(state.ledger), status)
    )

    state
  end

  defp notify_error(state, reason, detail) do
    notify(state, LiveFrames.error(reason, detail))
    state
  end

  ## Provider sends and audio

  # A failed send is REPORTED, never fatal: the socket's EXIT is the one
  # liveness signal, and a second owner tearing the call down here would race
  # it.
  defp send_provider(%{socket: nil} = state, _event), do: state

  defp send_provider(state, event) do
    case send_event(state, event) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning("voice_grok: provider send failed: #{inspect(reason)}")
        LiveTelemetry.provider_error(state.tasks.meta, inspect(reason))
        state
    end
  end

  defp send_event(state, event) do
    state.client.send_event(state.socket, event)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # A chunk goes to the provider once the session is ready, is held while it
  # starts, and is dropped otherwise. PCM16 samples are two bytes, so an odd
  # chunk is a corrupted frame, refused before it is sent.
  defp audio_route(%{muted?: true}, _audio), do: {:drop, :muted}

  defp audio_route(_state, audio) when rem(byte_size(audio), 2) != 0,
    do: {:drop, :odd_pcm16_frame}

  defp audio_route(%{phase: :ready, closing?: false}, _audio), do: :send

  defp audio_route(%{socket: socket, closing?: false}, _audio) when is_pid(socket), do: :hold

  defp audio_route(_state, _audio), do: {:drop, :provider_not_ready}

  defp hold_audio(state, audio) do
    held = state.held_audio_bytes + byte_size(audio)

    if held > @max_held_audio_bytes do
      Logger.warning("voice_grok: the session did not start before the held audio filled")
      fail_start(state, "The voice session did not start in time.")
    else
      {:noreply, %{state | held_audio: [audio | state.held_audio], held_audio_bytes: held}}
    end
  end

  defp drop_audio(state, reason) do
    Logger.debug("voice_grok: dropped microphone chunk (#{reason})")
    state
  end

  defp release_held_audio(%{held_audio: []} = state), do: state

  defp release_held_audio(state) do
    state.held_audio
    |> Enum.reverse()
    |> Enum.reduce(%{state | held_audio: [], held_audio_bytes: 0}, fn audio, acc ->
      send_provider(acc, XAIRealtimeClient.audio_append_event(audio))
    end)
  end

  ## The call record and captions

  defp open_record(state),
    do: %{
      state
      | tasks: CallTasks.open_record(state.tasks, state.config.engine, state.started_at)
    }

  defp record_caption(%{config: %Config{persist_transcripts?: false}}, _s, _t, _from, _to),
    do: :ok

  defp record_caption(state, speaker, text, start_ms, end_ms) do
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
           text,
           opts
         ) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("voice_grok: caption not recorded: #{inspect(reason)}")
    end
  end

  ## Ledger and timers

  defp tick_ledger(state), do: %{state | ledger: GrokLedger.tick(state.ledger, now(state))}

  defp enforce_ceiling(state) do
    if GrokLedger.over_ceiling?(state.ledger),
      do: end_call(state, :cost_limit),
      else: {:noreply, arm_ceiling_timer(state)}
  end

  # The session's length counts from the connection, as the provider counts
  # its own maximum.
  defp start_timers(state) do
    %{
      state
      | max_session_timer: Process.send_after(self(), :max_session_duration, remaining_ms(state))
    }
    |> schedule_usage_tick()
    |> arm_ceiling_timer()
  end

  defp remaining_ms(state), do: max(0, state.max_duration_ms - (now(state) - state.connected_ms))

  defp schedule_usage_tick(state),
    do: %{state | usage_timer: Process.send_after(self(), :usage_tick, state.usage_tick_ms)}

  # The budget's own deadline at the current text count, re-armed whenever a
  # text item moves it closer.
  defp arm_ceiling_timer(%{phase: :ready} = state) do
    cancel_timer(state.ceiling_timer)
    delay = GrokLedger.ms_until_ceiling(tick_ledger(state).ledger)
    %{state | ceiling_timer: Process.send_after(self(), :ceiling, delay)}
  end

  defp arm_ceiling_timer(state), do: state

  defp arm_start_deadline(state),
    do: %{
      state
      | start_timer: Process.send_after(self(), :start_deadline, state.start_deadline_ms)
    }

  defp cancel_start_timer(state) do
    cancel_timer(state.start_timer)
    %{state | start_timer: nil}
  end

  # Watches the client while audio it was sent is unreported: one timer,
  # started when there is something to hear and not reset by reports that move
  # nothing, so a client stuck on one offset still ends the call. Dropped once
  # nothing is outstanding.
  defp watch_playback(state) do
    case {GrokPlayback.awaiting_ack?(state.playback), state.ack_timer} do
      {true, nil} ->
        token = make_ref()
        timer = Process.send_after(self(), {:ack_timeout, token}, state.ack_timeout_ms)
        %{state | ack_timer: {timer, token, GrokPlayback.heard_ms(state.playback)}}

      {true, _watching} ->
        state

      {false, _watching} ->
        cancel_ack_timer(state)
    end
  end

  defp cancel_ack_timer(%{ack_timer: {timer, _token, _heard_ms}} = state) do
    cancel_timer(timer)
    %{state | ack_timer: nil}
  end

  defp cancel_ack_timer(state), do: state

  defp arm_vad_timer(state) do
    state = cancel_vad_timer(state)
    token = make_ref()

    %{
      state
      | vad_timer:
          {Process.send_after(self(), {:vad_grace_over, token}, state.vad_grace_ms), token}
    }
  end

  defp cancel_vad_timer(%{vad_timer: {timer, _token}} = state) do
    cancel_timer(timer)
    %{state | vad_timer: nil}
  end

  defp cancel_vad_timer(state), do: state

  defp arm_continuation_timer(state, id) do
    state = cancel_continuation_timer(state)
    timer = Process.send_after(self(), {:continuation_wait, id}, state.continuation_wait_ms)
    %{state | continuation_timer: timer}
  end

  defp cancel_continuation_timer(state) do
    cancel_timer(state.continuation_timer)
    %{state | continuation_timer: nil}
  end

  defp cancel_timers(state) do
    Enum.each(
      [
        state.start_timer,
        state.max_session_timer,
        state.usage_timer,
        state.ceiling_timer,
        state.continuation_timer
      ],
      &cancel_timer/1
    )

    %{
      state
      | start_timer: nil,
        max_session_timer: nil,
        usage_timer: nil,
        ceiling_timer: nil,
        continuation_timer: nil,
        tasks: CallTasks.cancel_timers(state.tasks)
    }
    |> cancel_ack_timer()
    |> cancel_vad_timer()
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) when is_reference(timer) do
    _remaining = Process.cancel_timer(timer)
    :ok
  end

  ## Telemetry and text

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

  defp provider_error_text(%{} = error) do
    [error.code || error.type, error.message]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(": ")
    |> case do
      "" -> "provider error"
      text -> text
    end
  end

  defp bounded_text(text) when byte_size(text) <= @max_assistant_text_bytes, do: text
  defp bounded_text(text), do: LiveText.one_line(text, @max_assistant_text_bytes)

  # Puts `key`, forgetting the oldest entry by `age` when the map is full: the
  # provider's word on it is the one least likely to still come.
  defp put_bounded(map, key, value, _age)
       when is_map_key(map, key) or map_size(map) < @max_tracked,
       do: Map.put(map, key, value)

  defp put_bounded(map, key, value, age) do
    {oldest, _value} = Enum.min_by(map, fn {_key, entry} -> age.(entry) end)
    map |> Map.delete(oldest) |> Map.put(key, value)
  end

  defp require_binary(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_value, name), do: {:error, {:missing, name}}

  # Milliseconds since the call started: the clock of the call's transcript,
  # so a task's offset and the words that asked for it are on one timeline.
  defp offset_ms(state), do: max(0, now(state) - state.started_ms)

  defp now(state), do: state.clock.()
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp unix_seconds, do: System.os_time(:second)
end
