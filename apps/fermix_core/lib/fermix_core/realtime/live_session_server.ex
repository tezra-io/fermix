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

  A hand-off's reply is said as one line, and in a call in the chat what
  cannot be said (a link, code, a table, a long answer) is shown in the chat
  through the bridge, the voice told so only once the row is written
  (`LiveText.split/2`, M56 §4.5). A reply its turn said is drawn from Computer
  History is shown, never said, unless OpenAI may carry it (M56 §9); a private
  call shows nothing.

  Every terminal exit — hang-up, ceiling, expiry, max duration, disconnect —
  runs one settle path: the companion is told the call is idle, in-flight
  delegations are cancelled through the bridge, the provider session is closed
  gracefully (bounded), the ledger is finalized, and `call_stop` telemetry
  carries WHY. `terminate/2` only releases what is still held.
  """

  use GenServer

  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.AccessGate.Pending, as: AccessPending
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.CallSpeech
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.ConversationRecorder
  alias FermixCore.Realtime.DeviceIdentity
  alias FermixCore.Realtime.LiveChat
  alias FermixCore.Realtime.LiveDelegation
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
  @context_wait_ms 1_000
  # How long after its audio has had time to play a reply counts as over: the
  # pet buffers a little before it plays.
  @reply_margin_ms 300

  # How far back a delegation's request reads. Long enough for a correction and
  # a confirmation, short enough that an unrelated earlier topic cannot be
  # mistaken for the current request. A private call's request is this window;
  # every call's sufficiency check reads it.
  @context_window_ms 30_000

  # The bound on a hand-off's request in the chat's conversation (M56 §4.1):
  # the exchange since the previous hand-off, cut from the front, since its end
  # is the ask.
  @exchange_max_bytes 4_096

  # Live caps an append at 500 tokens. These byte bounds sit under that with
  # room for multibyte text, and they are what stops a 40 KB tool dump from
  # being read aloud.
  @thinking_max_bytes 1_200
  @commentary_max_bytes 1_500
  # The wire's own bound on `task.summary` (protocol v2).
  @summary_max_chars 240
  @tool_progress_interval_ms 2_000
  # Unacked appends are kept only to explain a provider error. Bounded: this
  # process lives for a whole call.
  @max_pending_appends 64

  @insufficient_context "I did not catch that, could you say it again?"
  @interrupt_instruction "Stop speaking now and listen."
  @cancelled_line "The task was cancelled."
  @submit_failed_line "I could not start that task."
  @busy_line "I am already working on a task and one more is waiting."

  # What the voice is told about a result shown in the chat (M56 §4.5), after
  # the line it says, only once the row is written.
  @in_chat_line "The full result is in the chat."
  # What it says instead of a reply drawn from Computer History it may not
  # carry (M56 §9): the product's own words, never the reply's.
  @withheld_shown_line "The result is in the chat."
  @withheld_unshown_line "The result could not be put in the chat."
  @withheld_private_line "That result draws on your computer history, so it cannot be said on this call."

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

  @doc """
  The owner typed `text` in the chat (M56 §4.3). Sent, never awaited: the
  session tells the voice model as quiet context while a call in the chat is
  up, and drops it otherwise. Channels finds the session (`CallRegistry`).
  """
  @spec chat_typed(GenServer.server(), String.t()) :: :ok
  def chat_typed(session, text) when is_binary(text),
    do: GenServer.cast(session, {:chat, {:typed, text}})

  @doc """
  The chat answered the owner's typed message: `message` is that answer as the
  chat's store holds it, its Computer History marker included. Sent, never
  awaited, and told or dropped as `chat_typed/2` is.
  """
  @spec chat_answered(GenServer.server(), map()) :: :ok
  def chat_answered(session, %{role: "assistant", content: content} = message)
      when is_binary(content),
      do: GenServer.cast(session, {:chat, {:answered, message}})

  @typedoc """
  What a typed chat turn may read of the call in progress (M56 §4.4): when it
  started and how long it has run, its tasks as its record holds them, and what
  was said, the whole call (`CallSpeech`), never written anywhere.
  """
  @type context :: %{
          call_uuid: String.t(),
          started_at: DateTime.t(),
          elapsed_ms: non_neg_integer(),
          tasks: [CallRecord.task()],
          speech: CallSpeech.t()
        }

  @doc """
  The call's context, for `voice_call_context`. The caller bounds the wait:
  a session settling its call answers nothing until it is done.
  """
  @spec call_context(GenServer.server(), timeout()) :: {:ok, context()}
  def call_context(session, timeout), do: GenServer.call(session, :call_context, timeout)

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

    %{
      companion: Keyword.fetch!(opts, :companion),
      config: config,
      # The trace session id, a counter that restarts with the VM.
      call_id: to_string(session_scope),
      # The call's durable identity: the key of its record, on every frame and
      # telemetry event that names the call.
      call_uuid: DeviceIdentity.generate_uuid(),
      # When the call started: the claim's and the record's one start, and the
      # same moment on this session's clock, for how long it has run.
      started_at: DateTime.utc_now(),
      started_ms: clock.(),
      call_registry: Keyword.get(opts, :call_registry, CallRegistry),
      # The call's durable record (`CallRecord`), `nil` until the call starts.
      call_record: nil,
      record_opts: CallRecord.repo_opts(Keyword.get(opts, :record_repo, Repo)),
      api_key: Keyword.get(opts, :api_key),
      device_id: Keyword.get(opts, :device_id, "unknown"),
      agent_id: Keyword.get(opts, :agent_id, MemoryConfig.agent_id()),
      live_client: Keyword.get(opts, :live_client, OpenAILiveClient),
      live_pid: nil,
      voice_bridge: Keyword.get(opts, :voice_bridge),
      bridge_handle: nil,
      capability_registry: Keyword.get(opts, :capability_registry, CapabilityRegistry),
      prompt: Keyword.get(opts, :prompt),
      recorder_module: Keyword.get(opts, :recorder_module, ConversationRecorder),
      recorder_opts: Keyword.get(opts, :recorder_opts, []),
      clock: clock,
      unix_clock: Keyword.get(opts, :unix_clock, &unix_seconds/0),
      start_deadline_ms: Keyword.get(opts, :start_deadline_ms, @start_deadline_ms),
      close_deadline_ms: Keyword.get(opts, :close_deadline_ms, @close_deadline_ms),
      usage_tick_ms: Keyword.get(opts, :usage_tick_ms, @usage_tick_ms),
      context_wait_ms: Keyword.get(opts, :context_wait_ms, @context_wait_ms),
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
      # Where the next hand-off's exchange starts (M56 §4.1): the end of the
      # newest speech when the previous request was handed to the bridge, `nil`
      # until then (the exchange since the call started).
      exchange_since_ms: nil,
      delegations: LiveDelegation.new(),
      # Delegations whose turn read Computer History content, as each turn's
      # runner told it before its reply (M56 §9). Forgotten as each settles.
      history_tainted: MapSet.new(),
      turn_sessions: %{},
      last_activity_ms: %{},
      pending_appends: [],
      # What `session.start` carried, `nil` until it is sent: kept so a start
      # the provider refused over its input can be sent once more without it.
      start: nil,
      start_timer: nil,
      max_session_timer: nil,
      usage_timer: nil,
      reply_timer: nil,
      context_timers: %{},
      # `{intent_id, since_ms}`: the parked access-sensitive command the last
      # settled delegation's OWN turn asked the owner about, and when the owner
      # had last stopped speaking as that reply was delivered. Only speech after
      # it answers (`Capabilities.AccessGate`'s spoken yes); `nil` otherwise.
      access_window: nil,
      # Confirmed access-sensitive runs in flight: task ref -> delegation id.
      access_confirms: %{}
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
  # cancel (only the active delegation reached the bridge), the bridge close
  # (one stop for each turn the call registered, bounded by the call's length,
  # and the call store's release), and the graceful close: one send, then
  # at most `close_deadline_ms` waiting for `session.closed`. The stop's reply
  # goes out after `terminate/2`, so the wait covers that too: it cancels
  # timers, finds the bridge call already closed, and casts the socket close.
  def handle_call({:cancel_task, delegation_id}, _from, state) do
    case LiveDelegation.fetch(state.delegations, delegation_id) do
      {:ok, record} -> {:reply, :ok, start_next(cancel_delegation(state, record))}
      :error -> {:reply, {:error, :unknown_delegation}, state}
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
      tasks: recorded_tasks(state.call_record),
      speech: state.speech
    }

    {:reply, {:ok, context}, state}
  end

  @impl true
  def handle_cast({:chat, event}, state), do: {:noreply, mirror_chat(state, event)}

  def handle_cast({:audio_chunk, audio}, state) do
    case audio_drop_reason(state, audio) do
      nil ->
        state = send_provider(state, OpenAILiveClient.audio_append_event(audio))
        {:noreply, advance_operator_turn(state)}

      reason ->
        Logger.debug("voice_live: dropped microphone chunk (#{reason})")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:openai_live_event, event}, state), do: handle_live_event(event, state)

  def handle_info({:openai_live_error, reason}, state) do
    Logger.warning("voice_live: provider frame unreadable: #{inspect(reason)}")
    LiveTelemetry.provider_error(telemetry_meta(state), inspect(reason))
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

  def handle_info({:context_wait_expired, delegation_id}, state) do
    state = %{state | context_timers: Map.delete(state.context_timers, delegation_id)}

    case LiveDelegation.fetch(state.delegations, delegation_id) do
      {:ok, record} -> {:noreply, submit_or_clarify(state, record)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:delegation_event, delegation_id, event}, state) do
    case LiveDelegation.fetch(state.delegations, delegation_id) do
      {:ok, record} ->
        delegation_event(event, record, state)

      :error ->
        Logger.debug("voice_live: dropped stale event for delegation #{delegation_id}")
        {:noreply, state}
    end
  end

  # A confirmed access-sensitive command finished: its outcome answers the task
  # that carried the owner's yes, like any delegation result.
  def handle_info({ref, {status, outcome}}, %{access_confirms: confirms} = state)
      when is_reference(ref) and is_map_key(confirms, ref) and status in [:ok, :error] and
             is_binary(outcome) do
    Process.demonitor(ref, [:flush])
    {delegation_id, confirms} = Map.pop(confirms, ref)
    access_result(%{state | access_confirms: confirms}, delegation_id, spoken(status, outcome))
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{access_confirms: confirms} = state)
      when is_map_key(confirms, ref) do
    Logger.error("voice_live: a confirmed access-sensitive command crashed: #{inspect(reason)}")
    {delegation_id, confirms} = Map.pop(confirms, ref)
    unknown = {:error, AccessGate.outcome_unknown_text()}
    access_result(%{state | access_confirms: confirms}, delegation_id, unknown)
  end

  def handle_info(message, state) do
    Logger.debug("voice_live: unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{companion: _companion} = state) do
    cancel_timers(state)
    close_bridge_call(state)
    close_socket(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Call start

  defp start_call(state) do
    with {:ok, bridge} <- resolve_bridge(state),
         {:ok, instructions} <- resolve_prompt(state),
         {:ok, input} <- resolve_input(state, bridge),
         {:ok, api_key} <- require_binary(state.api_key, :api_key),
         {:ok, pid} <- open_socket(state, api_key) do
      send_session_start(%{state | voice_bridge: bridge, live_pid: pid}, instructions, input)
    else
      {:error, {:provider_refused, reason}} -> refuse_start(state, reason)
      {:error, reason} -> {:error, reason, notify_error(state, reason)}
    end
  end

  # The provider answered the handshake with a refusal — a 401 for a stale or
  # wrong key is the common one. Its own sentence is the only diagnosis anyone
  # gets, so it reaches the trace AND the companion's `detail` before the caller
  # is answered; a bare `provider_refused` sends the operator hunting a phantom.
  # The session stays up: the call never opened, and a crash here would close
  # the companion's connection with no frame on it at all.
  defp refuse_start(state, reason) do
    detail = LiveText.reason(reason)
    Logger.warning("voice_live: the provider refused the session: #{detail}")
    LiveTelemetry.provider_error(telemetry_meta(state), detail)
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
          telemetry_meta(state),
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
    with {:ok, live_md} <- LivePrompt.load(state.agent_id),
         {:ok, context} <- LivePrompt.context(state.agent_id, Config.conversation(state.config)) do
      capabilities = LivePrompt.eligible_capabilities(state.capability_registry)
      {:ok, LivePrompt.compose(live_md, capabilities, context)}
    end
  end

  # A call in the chat's conversation starts with the chat (M56 §4.3, D6),
  # read through the bridge before the call has a handle. A private call reads
  # none of it. A chat that cannot be read refuses the call, as a LIVE.md that
  # cannot be read does: the call does not start on half of what it was meant
  # to know.
  defp resolve_input(state, bridge) do
    case Config.conversation(state.config) do
      "chat" -> chat_input(bridge)
      "private" -> {:ok, []}
    end
  end

  defp chat_input(bridge) do
    with {:ok, window} <- bridge.conversation_window(LiveChat.window_bounds()) do
      {:ok, LiveChat.input(window)}
    end
  end

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
    state =
      %{state | provider_ready?: true, provider_session_id: id, expires_at: expires_at}
      |> cancel_start_timer()

    case open_bridge_call(state) do
      {:ok, state} ->
        LiveTelemetry.session_started(telemetry_meta(state))

        state =
          state
          |> start_timers()
          |> sync_mute()
          |> notify_call_ready()
          |> notify_state("listening")

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
    case LiveDelegation.create(state.delegations, id, offset_ms, now(state)) do
      {:ok, delegations} ->
        {:noreply, admit_delegation(%{state | delegations: delegations}, id)}

      {:duplicate, _delegations} ->
        Logger.debug("voice_live: ignored duplicate delegation #{id}")
        {:noreply, state}

      {:rejected, :too_many_pending, _delegations} ->
        {:noreply, refuse_delegation(state, id)}
    end
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
      LiveTelemetry.provider_error(telemetry_meta(state), provider_error_text(error))
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

    LiveTelemetry.provider_error(telemetry_meta(state), detail)

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
        send_thinking(state, nil, line)

      :drop ->
        Logger.debug("voice_live: a chat #{elem(event, 0)} message was not mirrored")
        state
    end
  end

  defp mirror_line(%{provider_ready?: true, closing?: false} = state, event) do
    case Config.conversation(state.config) do
      "chat" -> LiveChat.mirror_line(event)
      "private" -> :drop
    end
  end

  defp mirror_line(_state, _event), do: :drop

  # A mute applied before `session.started` was gated locally but never reached
  # the provider — it had no session to reach. It does now.
  defp sync_mute(%{muted?: true} = state), do: send_mute(state, true)
  defp sync_mute(state), do: state

  ## Delegations

  defp admit_delegation(state, id) do
    {:ok, record} = LiveDelegation.fetch(state.delegations, id)
    state = record_task(state, record, "created")

    case LiveDelegation.active(state.delegations) do
      %{id: ^id} -> submit_or_wait(state, record)
      _other -> notify_task(state, record, "pending", nil)
    end
  end

  defp submit_or_wait(state, record) do
    if LiveTranscript.sufficient?(state.transcript, record.offset_ms, @context_window_ms) do
      submit_delegation(state, record)
    else
      arm_context_wait(state, record.id)
    end
  end

  # The ONE bounded wait. A delegation arrives a moment before the transcript
  # delta that explains it, so waiting once is right — waiting twice, or
  # guessing, is how a partial sentence becomes a consequential action.
  defp submit_or_clarify(state, record) do
    if LiveTranscript.sufficient?(state.transcript, record.offset_ms, @context_window_ms) do
      submit_delegation(state, record)
    else
      state
      |> send_append(commentary(record.id, @insufficient_context), :commentary, record.id)
      |> settle_delegation(record, :failed, "insufficient_context")
      |> start_next()
    end
  end

  defp submit_delegation(state, record) do
    case access_answer(state, record) do
      {:confirmed, intent_id} -> confirm_access(%{state | access_window: nil}, record, intent_id)
      :declined -> submit_to_bridge(%{state | access_window: nil}, record)
      _no_window_or_no_answer -> submit_to_bridge(state, record)
    end
  end

  # The text is built once: what the bridge is given is what the turn persists
  # and what the record keeps (M56 §4.1).
  defp submit_to_bridge(state, record) do
    turn_session_id = mint_turn_session_id()
    text = request_text(state, record)
    request = delegation_request(state, record, turn_session_id, text)
    state = %{state | turn_sessions: Map.put(state.turn_sessions, record.id, turn_session_id)}

    case state.voice_bridge.submit(state.bridge_handle, request, delegation_callbacks(record.id)) do
      {:ok, task_ref} ->
        state
        |> close_exchange()
        |> run_delegation(record, task_ref, text)

      {:error, reason} ->
        Logger.warning(
          "voice_live: the bridge refused delegation #{record.id}: #{inspect(reason)}"
        )

        state
        |> send_append(commentary(record.id, @submit_failed_line), :commentary, record.id)
        |> settle_delegation(record, :failed, "submit_failed")
        |> start_next()
    end
  end

  # A task Live raises after a delegation's reply asked the owner to confirm the
  # command that delegation's own turn parked is read against what the owner
  # said since (`Capabilities.AccessGate`). A whole-utterance yes runs the
  # recorded command here, with no Fermix turn that could issue it again;
  # anything else drops the command and the task goes to Fermix as usual. A task
  # with no owner speech behind it (raised before the question) is no answer,
  # and the command waits.
  defp access_answer(%{access_window: {intent_id, since}} = state, %{offset_ms: offset_ms})
       when offset_ms > since do
    case LiveTranscript.user_text_since(state.transcript, since) do
      "" -> :no_answer
      text -> AccessGate.answer_spoken(intent_id, text)
    end
  end

  defp access_answer(_state, _record), do: :no_window

  # Every settle decides the answer window afresh. Only a delegation that
  # completed, and whose own turn parked a command still waiting, opens one: its
  # reply is what asked the owner. A failed or cancelled one (its reply, if any,
  # asked nothing) and a reply from a turn that parked nothing close it, so a
  # yes the owner said to something else can never confirm the command.
  defp settle_access_window(state, record, :completed),
    do: %{state | access_window: parked_by(state, record)}

  defp settle_access_window(state, _record, _failed_or_cancelled),
    do: %{state | access_window: nil}

  defp parked_by(state, record) do
    with {:ok, turn_session_id} <- Map.fetch(state.turn_sessions, record.id),
         {:ok, intent_id} <- AccessPending.pending_from(turn_session_id),
         since when is_integer(since) <- LiveTranscript.latest_user_end_ms(state.transcript) do
      {intent_id, since}
    else
      _nothing_parked -> nil
    end
  end

  # The same bookkeeping and bookends as a submitted task. No bridge task backs
  # it (`bridge_ref: nil`), so cancelling it makes no bridge call.
  defp confirm_access(state, record, intent_id) do
    task =
      Task.Supervisor.async_nolink(FermixCore.TaskSupervisor, fn ->
        AccessGate.confirm(intent_id)
      end)

    state = %{state | access_confirms: Map.put(state.access_confirms, task.ref, record.id)}
    run_delegation(state, record, nil, request_text(state, record))
  end

  defp spoken(:ok, outcome), do: {:ok, "The owner said yes. " <> outcome}
  defp spoken(:error, outcome), do: {:error, outcome}

  # A cancelled task is already settled; its late outcome is dropped.
  defp access_result(state, delegation_id, result) do
    case LiveDelegation.fetch(state.delegations, delegation_id) do
      {:ok, record} -> delegation_event({:result, result}, record, state)
      :error -> {:noreply, state}
    end
  end

  defp delegation_request(state, record, turn_session_id, text) do
    %{
      call_id: state.call_id,
      delegation_id: record.id,
      revision: record.revision,
      turn_session_id: turn_session_id,
      text: text,
      screen_frame: nil
    }
  end

  # In the chat's conversation a hand-off's request is the exchange since the
  # previous one, speaker labelled and bounded (M56 §4.1): it is persisted in
  # the chat's history, where the overlapping window would store the same words
  # twice. A private call keeps the window it always had.
  defp request_text(state, record) do
    case Config.conversation(state.config) do
      "chat" -> LiveText.tail(exchange_text(state, record), @exchange_max_bytes)
      "private" -> window_text(state, record)
    end
  end

  defp exchange_text(%{exchange_since_ms: nil} = state, _record),
    do: LiveTranscript.exchange_since(state.transcript, nil)

  # Live can raise two tasks from one sentence, and the second then has no
  # word of the owner's after the first went out. A request without the words
  # that asked for it is no request, so it is sent the window, the sentence
  # included, as a private call's would be.
  defp exchange_text(state, record) do
    case LiveTranscript.user_text_since(state.transcript, state.exchange_since_ms) do
      "" -> window_text(state, record)
      _new_words -> LiveTranscript.exchange_since(state.transcript, state.exchange_since_ms)
    end
  end

  defp window_text(state, record),
    do: LiveTranscript.context_since(state.transcript, record.offset_ms, @context_window_ms)

  # The request is with the bridge: the next one starts after what it carried.
  defp close_exchange(state) do
    case LiveTranscript.latest_end_ms(state.transcript) do
      nil -> state
      end_ms -> %{state | exchange_since_ms: end_ms}
    end
  end

  # The record keeps the words the task ran with: what was submitted to the
  # bridge, or, for a confirmed command, what the owner said around the yes. A
  # private call is kept apart from the chat, and its record keeps none.
  defp run_delegation(state, record, task_ref, text) do
    {:ok, delegations} =
      LiveDelegation.start(state.delegations, record.id, task_ref, record.revision)

    state = %{state | delegations: delegations}
    LiveTelemetry.delegation_start(telemetry_meta(state), delegation_meta(state, record))

    state
    |> record_task(record, "running", recorded_request(state, text))
    |> notify_task(record, "running", nil)
  end

  defp recorded_request(state, text) do
    case Config.conversation(state.config) do
      "chat" -> %{request: text}
      "private" -> %{}
    end
  end

  # The closures run in the BRIDGE's process, so they do exactly one thing:
  # forward to this session's mailbox. Anything heavier would run a voice call's
  # work inside an agent turn's process.
  defp delegation_callbacks(delegation_id) do
    session = self()

    %{
      progress: fn text ->
        send(session, {:delegation_event, delegation_id, {:progress, text}})
      end,
      activity: fn event ->
        send(session, {:delegation_event, delegation_id, {:activity, event}})
      end,
      history_tainted: fn ->
        send(session, {:delegation_event, delegation_id, :history_tainted})
      end,
      result: fn result ->
        send(session, {:delegation_event, delegation_id, {:result, result}})
      end
    }
  end

  defp delegation_event({:progress, text}, record, state) when is_binary(text) do
    {:noreply, send_thinking(state, record.id, LiveText.one_line(text, @thinking_max_bytes))}
  end

  defp delegation_event({:activity, {:tool_start, name}}, record, state) when is_binary(name) do
    if throttled?(state, record.id) do
      {:noreply, state}
    else
      state = %{state | last_activity_ms: Map.put(state.last_activity_ms, record.id, now(state))}
      {:noreply, send_thinking(state, record.id, "Using " <> name)}
    end
  end

  defp delegation_event({:activity, _event}, _record, state), do: {:noreply, state}

  # Sent by the turn's own process before its reply, so it is here first.
  defp delegation_event(:history_tainted, record, state),
    do: {:noreply, %{state | history_tainted: MapSet.put(state.history_tainted, record.id)}}

  defp delegation_event({:result, {:ok, text}}, record, state) when is_binary(text) do
    state = %{state | ledger: LiveLedger.record_backend_turn(state.ledger, %{})}
    answer = answer(state, record, text)

    state =
      state
      |> send_append(commentary(record.id, answer.spoken), :commentary, record.id)
      |> settle_delegation(record, :completed, answer.summary, answer.shown)
      |> start_next()

    {:noreply, state}
  end

  defp delegation_event({:result, {:cancelled}}, record, state) do
    state =
      state
      |> send_thinking(record.id, @cancelled_line)
      |> settle_delegation(record, :cancelled, "cancelled")
      |> start_next()

    {:noreply, state}
  end

  defp delegation_event({:result, {:error, reason}}, record, state) do
    text = reason_text(reason)

    state =
      state
      |> send_append(
        commentary(record.id, LiveText.sentence(text, @commentary_max_bytes)),
        :commentary,
        record.id
      )
      |> settle_delegation(record, :failed, LiveText.summary(text, @summary_max_chars))
      |> start_next()

    {:noreply, state}
  end

  defp delegation_event(event, record, state) do
    Logger.debug("voice_live: unhandled delegation event #{inspect(event)} for #{record.id}")
    {:noreply, state}
  end

  ## A hand-off's reply: what is said and what is shown

  # M56 §4.5 and §9: what of a hand-off's reply the voice is given to say, the
  # summary its task frame carries, and the chat row its result was shown at.
  # A reply drawn from Computer History reaches the voice only when OpenAI may
  # carry it, and a private call shows nothing.
  defp answer(state, record, text) do
    parts = LiveText.split(text, @commentary_max_bytes)

    case {Config.conversation(state.config), voice_may_carry?(state, record)} do
      {"private", true} -> said(text)
      {"private", false} -> withheld(@withheld_private_line, nil)
      {"chat", true} -> said_and_shown(state, record, parts)
      {"chat", false} -> shown_only(state, record, parts)
    end
  end

  defp voice_may_carry?(state, record),
    do: not MapSet.member?(state.history_tainted, record.id) or LiveChat.history_permitted?()

  # Every result of a private call, as every result was before: the reply cut
  # to a sentence, nothing shown.
  defp said(text) do
    %{
      spoken: LiveText.sentence(text, @commentary_max_bytes),
      summary: LiveText.summary(text, @summary_max_chars),
      shown: nil
    }
  end

  defp said_and_shown(_state, _record, {spoken, nil}), do: said(spoken)

  # The voice is told the rest is in the chat only once it is: a write that
  # failed leaves the line it says as it was.
  defp said_and_shown(state, record, {spoken, shown}) do
    case show(state, record, shown) do
      {:ok, row} ->
        budget = @commentary_max_bytes - byte_size(@in_chat_line) - 1

        %{
          spoken: LiveText.sentence(spoken, budget) <> " " <> @in_chat_line,
          summary: LiveText.summary(spoken, @summary_max_chars),
          shown: row
        }

      :error ->
        said(spoken)
    end
  end

  # The whole reply is shown (the chat is local) and none of it is said.
  defp shown_only(state, record, parts) do
    case show(state, record, whole(parts)) do
      {:ok, row} -> withheld(@withheld_shown_line, row)
      :error -> withheld(@withheld_unshown_line, nil)
    end
  end

  defp withheld(line, shown), do: %{spoken: line, summary: line, shown: shown}

  # The reply as written, its delimiter line aside.
  defp whole({spoken, nil}), do: spoken
  defp whole({spoken, spoken}), do: spoken
  defp whole({spoken, shown}), do: spoken <> "\n\n" <> shown

  # One row per task revision, written through the bridge, which answers the
  # row's `server_seq`. A write that fails is logged and the call goes on.
  defp show(state, record, text) do
    call = %{
      "uuid" => state.call_uuid,
      "event" => "shared",
      "task_id" => record.id,
      "revision" => record.revision
    }

    case bridge_call(fn -> state.voice_bridge.show(call, text) end) do
      {:ok, server_seq} when is_integer(server_seq) and server_seq > 0 ->
        {:ok, %{server_seq: server_seq, bytes: byte_size(text)}}

      {:error, reason} ->
        Logger.error(
          "voice_live: the result of #{record.id} could not be shown in the chat: " <>
            inspect(reason)
        )

        :error
    end
  end

  # The third delegation. Live is told out loud that Fermix is busy (so it can
  # say so), and the companion gets the refusal as a task frame rather than
  # nothing at all.
  defp refuse_delegation(state, id) do
    refused = %{id: id, revision: 1}

    state
    |> send_thinking(id, @busy_line)
    |> record_task(refused, "failed", %{summary: "busy"})
    |> notify_task(refused, "failed", "busy")
  end

  defp cancel_delegation(state, record) do
    cancel_on_bridge(state, record)
    settle_delegation(state, record, :cancelled, "cancelled")
  end

  defp cancel_on_bridge(%{bridge_handle: nil}, _record), do: :ok
  defp cancel_on_bridge(_state, %{bridge_ref: nil}), do: :ok

  defp cancel_on_bridge(state, record) do
    case bridge_call(fn -> state.voice_bridge.cancel(state.bridge_handle, record.bridge_ref) end) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("voice_live: cancel of #{record.id} failed: #{inspect(reason)}")
        :ok
    end
  end

  # `shown` is the chat row a completed result was shown at, `nil` when nothing
  # was shown (M56 §4.5).
  defp settle_delegation(state, record, status, summary, shown \\ nil) do
    meta = delegation_meta(state, record)

    state =
      case terminal(state.delegations, record.id, status, summary) do
        {:ok, finished, delegations} ->
          LiveTelemetry.delegation_stop(
            telemetry_meta(state),
            meta,
            Atom.to_string(status),
            duration_ms(state, record),
            shown
          )

          %{state | delegations: delegations}
          |> record_task(finished, Atom.to_string(status), %{summary: summary})
          |> notify_task(finished, Atom.to_string(status), summary, shown_seq(shown))

        {:error, :unknown_delegation} ->
          state
      end

    state
    |> settle_access_window(record, status)
    |> forget_delegation(record.id)
  end

  defp terminal(delegations, id, :completed, summary),
    do: LiveDelegation.complete(delegations, id, summary)

  defp terminal(delegations, id, :failed, summary),
    do: LiveDelegation.fail(delegations, id, summary)

  defp terminal(delegations, id, :cancelled, _summary), do: LiveDelegation.cancel(delegations, id)

  defp start_next(state) do
    case LiveDelegation.next_to_start(state.delegations) do
      {:ok, record, delegations} -> submit_or_wait(%{state | delegations: delegations}, record)
      :none -> state
    end
  end

  defp shown_seq(nil), do: nil
  defp shown_seq(%{server_seq: server_seq}), do: server_seq

  defp forget_delegation(state, id) do
    %{
      state
      | history_tainted: MapSet.delete(state.history_tainted, id),
        turn_sessions: Map.delete(state.turn_sessions, id),
        last_activity_ms: Map.delete(state.last_activity_ms, id),
        context_timers: cancel_context_timer(state.context_timers, id)
    }
  end

  defp throttled?(state, id) do
    case Map.get(state.last_activity_ms, id) do
      nil -> false
      last -> now(state) - last < @tool_progress_interval_ms
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
      |> cancel_in_flight_delegations()
      |> close_bridge_call()

    {seconds, state} = graceful_close(state)
    state = %{state | ledger: LiveLedger.finalize(state.ledger, seconds)}

    close_record(state, reason)
    notify_usage(state)
    LiveTelemetry.call_stop(telemetry_meta(state), call_measurements(state), reason)
    cancel_timers(state)
  end

  defp notify_terminal(state, :call_stop), do: state

  defp notify_terminal(state, :cost_limit) do
    state
    |> notify_usage("limit_reached")
    |> notify_error(:cost_limit)
  end

  defp notify_terminal(state, reason), do: notify_error(state, reason)

  defp cancel_in_flight_delegations(state) do
    state.delegations
    |> LiveDelegation.in_flight()
    |> Enum.reduce(state, fn record, acc -> cancel_delegation(acc, record) end)
  end

  defp close_bridge_call(%{bridge_handle: nil} = state), do: state

  defp close_bridge_call(state) do
    case bridge_call(fn -> state.voice_bridge.close_call(state.bridge_handle) end) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("voice_live: the bridge left the call open: #{inspect(reason)}")
    end

    %{state | bridge_handle: nil}
  end

  # Teardown has to finish even when the bridge process is already gone: the
  # ledger, the `call_stop` telemetry and the companion's final frames are what
  # is left of the call, and losing them to a dead peer is a worse outcome than
  # a logged close failure. A result shown in the chat is the same: a write
  # that raised or exited is a write that failed, and the call goes on.
  # Reported, never silent.
  defp bridge_call(fun) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

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

  defp notify_task(state, record, status, summary, server_seq \\ nil) do
    notify(
      state,
      LiveFrames.task(state.call_uuid, record.id, record.revision, status, summary, server_seq)
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
    LiveTelemetry.provider_error(telemetry_meta(state), inspect(reason))
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

  defp audio_drop_reason(%{provider_ready?: false}, _audio), do: :provider_not_ready
  defp audio_drop_reason(%{muted?: true}, _audio), do: :muted

  defp audio_drop_reason(_state, audio) when rem(byte_size(audio), 2) != 0,
    do: :odd_pcm16_frame

  defp audio_drop_reason(_state, _audio), do: nil

  ## The call record

  # Opened as the call starts, before any task can exist. A write that fails is
  # logged and the call goes on: the record is what a call leaves behind, and
  # a database hiccup must not end the conversation it records.
  defp open_record(state) do
    record = CallRecord.new(state.call_uuid, state.config.engine)
    report_record(CallRecord.open(record, state.started_at, state.record_opts), "open")
    %{state | call_record: record}
  end

  defp recorded_tasks(nil), do: []
  defp recorded_tasks(%CallRecord{tasks: tasks}), do: tasks

  # Every task state is written as it happens, so a crash loses nothing the
  # call had already done.
  defp record_task(state, record, task_state, fields \\ %{}) do
    call_record =
      CallRecord.put_task(state.call_record, record.id, record.revision, task_state, fields)

    report_record(CallRecord.write_tasks(call_record, state.record_opts), "write")
    %{state | call_record: call_record}
  end

  # Written before the final `usage` frame goes out, from the same settled
  # ledger, so the record is the source that frame agrees with. A call that
  # never reached `session.start` has no record to close.
  defp close_record(%{call_record: nil}, _reason), do: :ok

  defp close_record(state, reason) do
    usage = LiveLedger.usage_payload(state.ledger)

    state.call_record
    |> CallRecord.close(reason, usage, DateTime.utc_now(), state.record_opts, :nothing)
    |> report_record("close")
  end

  defp report_record(:ok, _action), do: :ok

  # Memory off is a configuration: there is no table to write.
  defp report_record({:error, :disabled}, _action), do: :ok

  defp report_record({:error, reason}, action) do
    Logger.error("voice_live: could not #{action} the call record: #{inspect(reason)}")
  end

  ## Bridge, recorder, timers

  defp open_bridge_call(state) do
    call = %{
      call_id: state.call_id,
      call_uuid: state.call_uuid,
      conversation: Config.conversation(state.config),
      device_id: state.device_id,
      persist?: state.config.persist_transcripts?,
      session_scope: state.call_id
    }

    with {:ok, handle} <- state.voice_bridge.open_call(call) do
      {:ok, %{state | bridge_handle: handle}}
    end
  end

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

  defp arm_context_wait(state, delegation_id) do
    timer =
      Process.send_after(self(), {:context_wait_expired, delegation_id}, state.context_wait_ms)

    %{state | context_timers: Map.put(state.context_timers, delegation_id, timer)}
  end

  defp cancel_context_timer(timers, id) do
    case Map.pop(timers, id) do
      {nil, timers} -> timers
      {timer, timers} -> cancel_timer(timer) && timers
    end
  end

  defp cancel_timers(state) do
    Enum.each(
      [state.start_timer, state.max_session_timer, state.usage_timer] ++
        Map.values(state.context_timers),
      &cancel_timer/1
    )

    %{
      cancel_reply_timer(state)
      | start_timer: nil,
        max_session_timer: nil,
        usage_timer: nil,
        context_timers: %{}
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

  defp telemetry_meta(state) do
    %{
      session_id: state.call_id,
      call_uuid: state.call_uuid,
      device_id: state.device_id,
      model: state.config.model,
      voice: state.config.voice,
      provider_session_id: state.provider_session_id
    }
  end

  defp delegation_meta(state, record) do
    %{
      delegation_id: record.id,
      revision: record.revision,
      turn_session_id: Map.get(state.turn_sessions, record.id, "voice_delegation_unstarted")
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

  defp duration_ms(state, record), do: max(0, now(state) - record.created_at_ms)

  defp mint_turn_session_id do
    "voice_delegation_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp provider_error_text(error) when is_map(error) do
    Map.get(error, "message") || Map.get(error, "type") || inspect(error)
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp require_binary(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_value, name), do: {:error, {:missing, name}}

  defp now(state), do: state.clock.()

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp unix_seconds, do: System.os_time(:second)
end
