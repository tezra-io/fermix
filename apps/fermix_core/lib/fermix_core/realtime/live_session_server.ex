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

  Every terminal exit — hang-up, ceiling, expiry, max duration, disconnect —
  runs one settle path: the companion is told the call is idle, in-flight
  delegations are cancelled through the bridge, the provider session is closed
  gracefully (bounded), the ledger is finalized, and `call_stop` telemetry
  carries WHY. `terminate/2` only releases what is still held.
  """

  use GenServer

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.ConversationRecorder
  alias FermixCore.Realtime.LiveDelegation
  alias FermixCore.Realtime.LiveFrames
  alias FermixCore.Realtime.LiveLedger
  alias FermixCore.Realtime.LivePrompt
  alias FermixCore.Realtime.LiveTelemetry
  alias FermixCore.Realtime.LiveText
  alias FermixCore.Realtime.LiveTranscript
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

  # How far back a delegation's request reads. Long enough for a correction and
  # a confirmation, short enough that an unrelated earlier topic cannot be
  # mistaken for the current request.
  @context_window_ms 30_000

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
      {:ok, initial_state(opts, config)}
    else
      {:stop, {:invalid_engine, config.engine}}
    end
  end

  defp initial_state(opts, config) do
    clock = Keyword.get(opts, :clock, &monotonic_ms/0)
    session_scope = Keyword.get(opts, :session_scope, "voice_live:unknown")

    %{
      companion: Keyword.fetch!(opts, :companion),
      config: config,
      call_id: to_string(session_scope),
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
      provider_ready?: false,
      provider_session_id: nil,
      expires_at: nil,
      max_duration_ms: config.max_session_minutes * @minute_ms,
      muted?: false,
      provider_muted?: false,
      speaking?: false,
      closing?: false,
      closed_report: :never,
      ledger: LiveLedger.new(config.max_estimated_cost_cents_per_session, clock.()),
      transcript: LiveTranscript.new(),
      delegations: LiveDelegation.new(),
      turn_sessions: %{},
      last_activity_ms: %{},
      pending_appends: [],
      start_timer: nil,
      max_session_timer: nil,
      usage_timer: nil,
      context_timers: %{}
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
      state
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
      %{state | muted?: enabled?}
      |> notify_state(if(enabled?, do: "muted", else: "listening"))
      |> send_mute(enabled?)

    {:reply, :ok, state}
  end

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

  @impl true
  def handle_cast({:audio_chunk, audio}, state) do
    case audio_drop_reason(state, audio) do
      nil ->
        {:noreply, send_provider(state, OpenAILiveClient.audio_append_event(audio))}

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
         {:ok, api_key} <- require_binary(state.api_key, :api_key),
         {:ok, pid} <- open_socket(state, api_key) do
      send_session_start(%{state | voice_bridge: bridge, live_pid: pid}, instructions)
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

  defp send_session_start(state, instructions) do
    event =
      OpenAILiveClient.session_start_event(state.config, instructions,
        event_id: OpenAILiveClient.new_event_id()
      )

    case send_event(state, event) do
      :ok ->
        LiveTelemetry.call_start(telemetry_meta(state), state.max_duration_ms)
        {:ok, arm_start_deadline(state)}

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
    with {:ok, live_md} <- LivePrompt.load(state.agent_id) do
      {:ok,
       LivePrompt.compose(live_md, LivePrompt.eligible_capabilities(state.capability_registry))}
    end
  end

  # Tagged, because `start_call/1`'s `with` gathers four different failures and
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
    state = if state.speaking?, do: state, else: notify_state(state, "speaking")
    notify(state, LiveFrames.audio_delta(delta))
    {:noreply, state}
  end

  defp handle_live_event({:transcript_delta, speaker, delta, start_ms, end_ms}, state) do
    state = %{
      state
      | transcript: LiveTranscript.append(state.transcript, speaker, delta, start_ms, end_ms)
    }

    notify(state, LiveFrames.caption(Atom.to_string(speaker), delta, start_ms, end_ms))

    record_caption(state, speaker, delta, start_ms, end_ms)
    {:noreply, resume_listening(state, speaker)}
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
    Logger.warning("voice_live: provider error: #{inspect(error)}")
    LiveTelemetry.provider_error(telemetry_meta(state), provider_error_text(error))
    {:noreply, fail_pending_append(state, Map.get(error, "client_event_id"))}
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

  # A mute applied before `session.started` was gated locally but never reached
  # the provider — it had no session to reach. It does now.
  defp sync_mute(%{muted?: true} = state), do: send_mute(state, true)
  defp sync_mute(state), do: state

  ## Delegations

  defp admit_delegation(state, id) do
    {:ok, record} = LiveDelegation.fetch(state.delegations, id)

    case LiveDelegation.active(state.delegations) do
      %{id: ^id} -> submit_or_wait(state, record)
      _other -> notify_task(state, record, "pending", nil)
    end
  end

  defp submit_or_wait(state, record) do
    if LiveTranscript.sufficient?(state.transcript, record.offset_ms) do
      submit_delegation(state, record)
    else
      arm_context_wait(state, record.id)
    end
  end

  # The ONE bounded wait. A delegation arrives a moment before the transcript
  # delta that explains it, so waiting once is right — waiting twice, or
  # guessing, is how a partial sentence becomes a consequential action.
  defp submit_or_clarify(state, record) do
    if LiveTranscript.sufficient?(state.transcript, record.offset_ms) do
      submit_delegation(state, record)
    else
      state
      |> send_append(commentary(record.id, @insufficient_context), :commentary, record.id)
      |> settle_delegation(record, :failed, "insufficient_context")
      |> start_next()
    end
  end

  defp submit_delegation(state, record) do
    turn_session_id = mint_turn_session_id()
    request = delegation_request(state, record, turn_session_id)
    state = %{state | turn_sessions: Map.put(state.turn_sessions, record.id, turn_session_id)}

    case state.voice_bridge.submit(state.bridge_handle, request, delegation_callbacks(record.id)) do
      {:ok, task_ref} ->
        run_delegation(state, record, task_ref)

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

  defp delegation_request(state, record, turn_session_id) do
    %{
      call_id: state.call_id,
      delegation_id: record.id,
      revision: record.revision,
      turn_session_id: turn_session_id,
      text: LiveTranscript.context_since(state.transcript, record.offset_ms, @context_window_ms),
      screen_frame: nil
    }
  end

  defp run_delegation(state, record, task_ref) do
    {:ok, delegations} =
      LiveDelegation.start(state.delegations, record.id, task_ref, record.revision)

    state = %{state | delegations: delegations}
    LiveTelemetry.delegation_start(telemetry_meta(state), delegation_meta(state, record))
    notify_task(state, record, "running", nil)
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

  defp delegation_event({:result, {:ok, text}}, record, state) when is_binary(text) do
    state = %{state | ledger: LiveLedger.record_backend_turn(state.ledger, %{})}

    state =
      state
      |> send_append(
        commentary(record.id, LiveText.sentence(text, @commentary_max_bytes)),
        :commentary,
        record.id
      )
      |> settle_delegation(record, :completed, LiveText.summary(text, @summary_max_chars))
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

  # The third delegation. Live is told out loud that Fermix is busy (so it can
  # say so), and the companion gets the refusal as a task frame rather than
  # nothing at all.
  defp refuse_delegation(state, id) do
    state
    |> send_thinking(id, @busy_line)
    |> notify_task(%{id: id, revision: 1}, "failed", "busy")
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

  defp settle_delegation(state, record, status, summary) do
    meta = delegation_meta(state, record)

    state =
      case terminal(state.delegations, record.id, status, summary) do
        {:ok, finished, delegations} ->
          LiveTelemetry.delegation_stop(
            telemetry_meta(state),
            meta,
            Atom.to_string(status),
            duration_ms(state, record)
          )

          notify_task(
            %{state | delegations: delegations},
            finished,
            Atom.to_string(status),
            summary
          )

        {:error, :unknown_delegation} ->
          state
      end

    forget_delegation(state, record.id)
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

  defp forget_delegation(state, id) do
    %{
      state
      | turn_sessions: Map.delete(state.turn_sessions, id),
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
  # a logged close failure. Reported, never silent.
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

  defp resume_listening(%{speaking?: true} = state, :user), do: notify_state(state, "listening")
  defp resume_listening(state, _speaker), do: state

  defp notify_call_ready(state) do
    notify(
      state,
      LiveFrames.call_ready(
        state.config.engine,
        state.call_id,
        state.provider_session_id,
        state.expires_at
      )
    )

    state
  end

  defp notify_task(state, record, status, summary) do
    notify(state, LiveFrames.task(record.id, record.revision, status, summary))
    state
  end

  defp notify_usage(state, status \\ nil) do
    notify(state, LiveFrames.usage(LiveLedger.usage_payload(state.ledger), status))
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

  ## Bridge, recorder, timers

  defp open_bridge_call(state) do
    call = %{
      call_id: state.call_id,
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

    %{state | start_timer: nil, max_session_timer: nil, usage_timer: nil, context_timers: %{}}
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
