defmodule FermixCore.Realtime.SessionServer do
  @moduledoc """
  Owns one local full-duplex Realtime voice call.
  """

  use GenServer

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.ComputerUse.Probe, as: ComputerUseProbe
  alias FermixCore.ComputerUse.SessionManager, as: ComputerUseSessionManager
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.ConversationRecorder
  alias FermixCore.Realtime.CostTracker
  alias FermixCore.Realtime.OpenAIClient
  alias FermixCore.Realtime.ScreenFeed
  alias FermixCore.Realtime.ScreenShare
  alias FermixCore.Realtime.Telemetry, as: RealtimeTelemetry
  alias FermixCore.Realtime.ToolBridge
  alias FermixCore.Tools.Telemetry, as: ToolsTelemetry

  require Logger

  @pcm16_bytes_per_ms 48
  @minute_ms 60_000

  # Screen-feed frames are cheap context, not a record: keep only the newest few
  # in the provider conversation and evict the rest, or every retained frame is
  # re-read (and re-billed) on every later response for the rest of the call.
  # `low` detail is the continuous-perception end of the dial — a precision look
  # is what `computer_use` screenshots are for, and those still go at `high`.
  @frames_retained 2
  @frame_detail "low"
  # Backpressure for the queued frame path: past this many messages waiting on the
  # socket process, the uplink is behind and the newest frame is worth more than a
  # backlog of stale ones.
  @max_pending_sends 4
  # `call_start` blocks while the upstream WebSocket handshake completes.
  # Keep this strictly above `OpenAIClient.handshake_timeout_ms/0` so an
  # upstream stall surfaces as a WebSockex timeout, not a GenServer.call exit.
  @call_start_timeout_ms 10_000
  @runtime_reload_timeout_ms 10_000
  @default_reconnect_backoff_ms [1_000, 2_000, 4_000]

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

  @spec call_start(GenServer.server()) :: :ok | {:error, term()}
  def call_start(server), do: GenServer.call(server, :call_start, @call_start_timeout_ms)

  # Audio is fire-and-forget media: a cast, so a busy session loop (e.g. running
  # a tool) never blocks the socket reader's send. Control verbs below stay
  # `GenServer.call` so the caller still gets an ack. Drops are logged, not
  # silently swallowed.
  @spec audio_chunk(GenServer.server(), binary()) :: :ok
  def audio_chunk(server, audio) when is_binary(audio),
    do: GenServer.cast(server, {:audio_chunk, audio})

  @spec interrupt(GenServer.server(), non_neg_integer() | nil) :: :ok | {:error, term()}
  def interrupt(server, audio_end_ms \\ nil)
      when is_nil(audio_end_ms) or (is_integer(audio_end_ms) and audio_end_ms >= 0) do
    GenServer.call(server, {:interrupt, audio_end_ms})
  end

  @spec mute(GenServer.server(), boolean()) :: :ok
  def mute(server, enabled?) when is_boolean(enabled?),
    do: GenServer.call(server, {:mute, enabled?})

  @spec call_stop(GenServer.server()) :: :ok
  def call_stop(server), do: GenServer.call(server, :call_stop)

  @spec handle_provider_event(GenServer.server(), term()) :: :ok
  def handle_provider_event(server, event), do: GenServer.call(server, {:provider_event, event})

  @spec openai_pid(GenServer.server()) :: pid() | nil
  def openai_pid(server), do: GenServer.call(server, :openai_pid)

  @spec usage(GenServer.server()) :: CostTracker.t()
  def usage(server), do: GenServer.call(server, :usage)

  @spec reload_runtime(GenServer.server()) ::
          {:ok, %{tools: non_neg_integer()}} | {:error, term()}
  def reload_runtime(server),
    do: GenServer.call(server, :reload_runtime, @runtime_reload_timeout_ms)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = Keyword.get_lazy(opts, :config, &Config.current/0)
    capability_registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)
    skill_registry = Keyword.get(opts, :skill_registry, SkillRegistry)
    device_id = Keyword.get(opts, :device_id, "unknown")
    session_scope = Keyword.get(opts, :session_scope, :root)

    context =
      opts
      |> Keyword.get_lazy(:context, fn -> default_context(device_id) end)
      |> Map.put_new(:capability_registry, capability_registry)
      |> Map.put_new(:skill_registry, skill_registry)
      |> Map.put_new(:session_id, to_string(session_scope))
      # The voice call IS the attended human (COMPUTER_USE.md §7.6) — tag its tool
      # context so computer-use can start a host session, exactly as the text turn
      # tags `:interactive` in TurnRunner. `:voice` is already whitelisted in
      # `ComputerUse.Safety`. put_new so a test can override.
      |> Map.put_new(:computer_use_origin, :voice)

    prompt_loader = Keyword.get(opts, :prompt_loader)

    case realtime_runtime(opts, prompt_loader, capability_registry, skill_registry) do
      {:ok, runtime} ->
        capabilities = runtime.capabilities

        {:ok,
         %{
           companion: Keyword.fetch!(opts, :companion),
           # Tool calls run on this supervisor via `async_nolink` so a slow tool
           # never blocks the session's mailbox (the deadlock this fixes). Passed
           # explicitly; defaults to the Realtime tree's supervisor.
           task_supervisor:
             Keyword.get(opts, :task_supervisor, FermixCore.Realtime.TaskSupervisor),
           # task ref -> {%Task{}, call}. The call is kept for the error/crash
           # path (needs the call_id to answer OpenAI); the task is kept so
           # teardown/reconnect can shut in-flight tools down. Concurrent-safe.
           pending_tool_calls: %{},
           config: config,
           device_id: device_id,
           session_scope: session_scope,
           openai_client: Keyword.get(opts, :openai_client, OpenAIClient),
           openai_pid: nil,
           api_key: Keyword.get(opts, :api_key),
           safety_identifier: Keyword.get(opts, :safety_identifier),
           capability_registry: capability_registry,
           skill_registry: skill_registry,
           available_skills: runtime.available_skills,
           runtime_context: runtime.context,
           runtime_profile: runtime.profile,
           capabilities: capabilities,
           tool_bridge: ToolBridge.new(capabilities, context),
           tool_context: context,
           runtime_capabilities_override: Keyword.get(opts, :capabilities),
           prompt_loader: prompt_loader,
           recorder_module: Keyword.get(opts, :recorder_module, ConversationRecorder),
           recorder_opts: Keyword.get(opts, :recorder_opts, []),
           usage: CostTracker.new(config),
           muted?: false,
           max_session_timer: nil,
           user_transcript: "",
           assistant_transcript: "",
           reconnect_backoff_ms:
             Keyword.get(opts, :reconnect_backoff_ms, @default_reconnect_backoff_ms),
           reconnect_attempts: 0,
           reconnect_timer: nil,
           session_update_event: nil,
           provider_ready?: false,
           current_item_id: nil,
           response_started_ms: nil,
           # Screen perception (M9.5). The feed is started + linked by THIS process
           # (never from a tool task, whose lifetime is one call), so it dies with
           # the call. `screen_frame_items` are the provider item ids of the frames
           # currently in context, newest first; `screen_share_resume?` re-opens the
           # feed after a reconnect, since the frames + ids belong to the old
           # server-side conversation and cannot cross it.
           screen_feed: nil,
           screen_display: nil,
           screen_frame_items: [],
           screen_share_resume?: false,
           screen_feed_module: Keyword.get(opts, :screen_feed_module, ScreenFeed),
           screen_feed_opts: Keyword.get(opts, :screen_feed_opts, []),
           screen_probe: Keyword.get(opts, :screen_probe, &ComputerUseProbe.run/0)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:call_start, _from, %{session_update_event: nil} = state) do
    with {:ok, openai_pid, state} <- open_openai_session(state),
         {:ok, event} <- build_session_update_event(state) do
      case send_provider_event(state.openai_client, openai_pid, event) do
        :ok ->
          RealtimeTelemetry.call_start(telemetry_meta(state))

          state =
            %{state | openai_pid: openai_pid, session_update_event: event, provider_ready?: false}

          {:reply, :ok, state}

        {:error, reason} ->
          state.openai_client.close(openai_pid)
          notify_call_start_error(state, reason)
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        notify_call_start_error(state, reason)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:call_start, _from, %{openai_pid: openai_pid, provider_ready?: true} = state)
      when is_pid(openai_pid) do
    notify(state.companion, %{type: "state", state: "listening"})
    {:reply, :ok, state}
  end

  def handle_call(:call_start, _from, %{openai_pid: openai_pid} = state)
      when is_pid(openai_pid) do
    {:reply, :ok, state}
  end

  def handle_call(:call_start, _from, state) do
    {:reply, {:error, :provider_not_connected}, state}
  end

  def handle_call({:interrupt, audio_end_ms}, _from, %{openai_pid: openai_pid} = state)
      when is_pid(openai_pid) do
    with :ok <- maybe_send_truncate(openai_pid, state, audio_end_ms),
         :ok <- send_openai(state, OpenAIClient.cancel_response_event()) do
      notify(state.companion, %{type: "playback_stop"})
      notify(state.companion, %{type: "state", state: "listening"})

      {:reply, :ok, %{state | current_item_id: nil}}
    else
      {:error, reason} ->
        report_provider_send_error(state, reason)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:interrupt, _audio_end_ms}, _from, state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:mute, enabled?}, _from, state) do
    notify(state.companion, %{type: "state", state: if(enabled?, do: "muted", else: "listening")})
    {:reply, :ok, %{state | muted?: enabled?}}
  end

  def handle_call(:call_stop, _from, state) do
    notify(state.companion, %{type: "state", state: "idle"})

    RealtimeTelemetry.call_stop(
      telemetry_meta(state),
      usage_measurements(state.usage),
      :call_stop
    )

    # The call is over, so the process ends: `terminate/2` does the releasing, and
    # nothing is left half-torn-down for a later call to inherit.
    {:stop, {:shutdown, :call_stop}, :ok, state}
  end

  def handle_call({:provider_event, event}, _from, state) do
    {:reply, :ok, handle_provider_event_internal(event, state)}
  end

  def handle_call(:openai_pid, _from, state), do: {:reply, state.openai_pid, state}
  def handle_call(:usage, _from, state), do: {:reply, state.usage, state}

  def handle_call(:reload_runtime, _from, state) do
    with {:ok, refreshed} <- refresh_runtime(state),
         {:ok, refreshed} <- refresh_provider_runtime(refreshed) do
      {:reply, {:ok, %{tools: length(refreshed.capabilities)}}, refreshed}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:audio_chunk, _audio}, %{muted?: true} = state) do
    Logger.debug("Realtime session dropped audio chunk while muted")
    {:noreply, state}
  end

  def handle_cast({:audio_chunk, audio}, %{openai_pid: openai_pid} = state)
      when is_pid(openai_pid) do
    case send_openai(state, OpenAIClient.audio_append_event(audio)) do
      :ok ->
        usage = CostTracker.add_input_audio_ms(state.usage, audio_duration_ms(audio))
        state = %{state | usage: usage}

        notify_usage(state, "estimated")
        enforce_audio_limits(state, usage)

      {:error, reason} ->
        report_provider_send_error(state, reason)
        {:noreply, state}
    end
  end

  # `openai_pid` is nil ONLY inside the bounded reconnect window. Audio arriving
  # then is correctly discarded — the connection is coming back.
  def handle_cast({:audio_chunk, _audio}, %{reconnect_timer: timer} = state)
      when is_reference(timer) do
    Logger.debug("Realtime session dropped audio chunk while reconnecting")
    {:noreply, state}
  end

  # Any OTHER chunk with no provider is the state that must not exist. End loud on
  # the first one rather than stream audio into a void: this is the executable form
  # of the invariant, and on its own it would have turned the incident into a
  # 100 ms blip instead of a 43-second freeze.
  def handle_cast({:audio_chunk, _audio}, state) do
    {:stop, {:shutdown, :provider_session_missing}, state}
  end

  defp enforce_audio_limits(state, usage) do
    case CostTracker.enforce_limits(usage) do
      :ok ->
        {:noreply, state}

      {:stop, reason} ->
        # The companion has no handler for `usage`, so this frame alone was
        # invisible — the ceiling used to stop the world with no log, no
        # telemetry and nothing the operator could see. `end_call` makes it a
        # real, traced ending.
        notify(state.companion, %{
          type: "usage",
          status: "limit_reached",
          reason: Atom.to_string(reason)
        })

        end_call(state, reason)
    end
  end

  @impl true
  def handle_info({:openai_realtime_event, event}, state) do
    {:noreply, handle_provider_event_internal(event, state)}
  end

  # A tool task finished (async_nolink). Flush its stale :DOWN, then answer
  # OpenAI + the companion with the exact same success/error handling the
  # inline path used. Guarded on the ref so it never shadows the other
  # 2-tuple/EXIT clauses below.
  def handle_info({ref, result}, %{pending_tool_calls: pending} = state)
      when is_reference(ref) and is_map_key(pending, ref) do
    Process.demonitor(ref, [:flush])
    {{_task, call}, remaining} = Map.pop(pending, ref)
    {:noreply, apply_tool_result(result, call, %{state | pending_tool_calls: remaining})}
  end

  # A tool task crashed. OpenAI is still waiting for this call's output, so
  # answer it with the failure rather than hanging the turn.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending_tool_calls: pending} = state)
      when is_map_key(pending, ref) do
    {{_task, call}, remaining} = Map.pop(pending, ref)
    error = {:error, %{call_id: call_id(call), reason: {:tool_task_crashed, reason}}}
    {:noreply, apply_tool_result(error, call, %{state | pending_tool_calls: remaining})}
  end

  # One screen frame from the feed. It is appended as PASSIVE context — no
  # `response.create` — so continuous perception never spends a turn; the user's
  # next utterance (server VAD) is what makes the newest frames matter.
  def handle_info({:screen_feed, {:frame, frame}}, state) do
    {:noreply, append_screen_frame(state, frame)}
  end

  def handle_info({:screen_feed, {:stopped, reason, measurements}}, state) do
    {:noreply, note_screen_feed_stopped(state, reason, measurements)}
  end

  def handle_info({:openai_realtime_disconnect, _reason}, %{session_update_event: nil} = state) do
    {:noreply, state}
  end

  def handle_info({:openai_realtime_disconnect, _reason}, state) do
    case schedule_reconnect(state) do
      {:ok, state} ->
        {:noreply, state}

      :exhausted ->
        end_call(state, :provider_disconnected)
    end
  end

  def handle_info({:openai_realtime_error, reason}, state) do
    notify(state.companion, %{type: "error", reason: reason_to_string(reason)})
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, _reason}, %{openai_pid: pid, session_update_event: event} = state)
      when not is_nil(event) do
    case schedule_reconnect(state) do
      {:ok, state} ->
        {:noreply, state}

      :exhausted ->
        end_call(state, :provider_disconnected)
    end
  end

  # The feed exited. It reports its typed reason from `terminate/2`, so this only
  # clears the pid for the case where that message has not landed yet.
  def handle_info({:EXIT, pid, _reason}, %{screen_feed: pid} = state) do
    {:noreply, %{state | screen_feed: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:reconnect_attempt, state) do
    case attempt_reconnect(state) do
      {:ok, openai_pid, state} ->
        {:noreply,
         %{
           state
           | openai_pid: openai_pid,
             provider_ready?: false,
             reconnect_attempts: 0,
             reconnect_timer: nil
         }}

      {:error, _reason, state} ->
        case schedule_reconnect(state) do
          {:ok, state} ->
            {:noreply, state}

          :exhausted ->
            end_call(state, :provider_disconnected)
        end
    end
  end

  def handle_info(:max_session_duration, state) do
    end_call(state, :max_session_duration)
  end

  @impl true
  def terminate(_reason, %{tool_context: context} = state) do
    # THE teardown. Every way this call can end — `end_call`, `call_stop`, a crash,
    # a supervisor shutdown — arrives here, so the releasing lives in exactly one
    # place and cannot be skipped by whichever exit fired. All of it is idempotent.
    cancel_pending_tool_calls(state)
    cancel_timers(state)
    # Graceful, not link-propagated: the feed traps exits, and only its own
    # `terminate/2` releases the capture sidecar (Port close alone leaves the OS
    # process alive, which is how a leaked client wedges capture system-wide).
    close_screen_feed(state, :requested)
    # A host computer-use session must never outlive the attended call (§7.6).
    ComputerUseSessionManager.abort(context)
    close_openai(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp open_openai_session(state) do
    with {:ok, api_key} <- require_binary(state.api_key, :api_key),
         {:ok, safety_identifier} <- require_binary(state.safety_identifier, :safety_identifier),
         {:ok, pid} <-
           state.openai_client.start_link(
             url: OpenAIClient.url(state.config),
             headers: OpenAIClient.headers(api_key, safety_identifier),
             parent: self()
           ) do
      {:ok, pid, state}
    end
  end

  defp build_session_update_event(state) do
    with {:ok, instructions} <- session_instructions(state) do
      # `screen_share` is a SESSION verb, not a registry capability: it only means
      # anything while this provider session is live, so the session advertises it
      # (and executes it) itself, leaving `ToolBridge` a pure capability bridge.
      tools = ToolBridge.to_openai_tools(state.capabilities) ++ ScreenShare.tools(state.config)
      {:ok, OpenAIClient.session_update_event(state.config, instructions, tools)}
    end
  end

  defp refresh_runtime(state) do
    with {:ok, runtime} <- realtime_runtime_from_state(state) do
      {:ok,
       %{
         state
         | available_skills: runtime.available_skills,
           runtime_context: runtime.context,
           runtime_profile: runtime.profile,
           capabilities: runtime.capabilities,
           tool_bridge: ToolBridge.new(runtime.capabilities, state.tool_context)
       }}
    end
  end

  defp realtime_runtime_from_state(%{prompt_loader: loader} = state)
       when is_function(loader, 1) do
    capabilities =
      state.runtime_capabilities_override || default_capabilities(state.capability_registry)

    {:ok,
     %{
       available_skills: [],
       context: nil,
       profile: nil,
       capabilities: capabilities
     }}
  end

  defp realtime_runtime_from_state(state) do
    realtime_runtime([], nil, state.capability_registry, state.skill_registry)
  end

  defp refresh_provider_runtime(%{session_update_event: nil} = state), do: {:ok, state}

  defp refresh_provider_runtime(%{openai_pid: openai_pid} = state) when is_pid(openai_pid) do
    with {:ok, event} <- build_session_update_event(state),
         :ok <- send_provider_event(state.openai_client, openai_pid, event) do
      {:ok, %{state | session_update_event: event}}
    end
  end

  defp refresh_provider_runtime(state) do
    with {:ok, event} <- build_session_update_event(state) do
      {:ok, %{state | session_update_event: event}}
    end
  end

  defp schedule_reconnect(state) do
    case Enum.at(state.reconnect_backoff_ms, state.reconnect_attempts) do
      nil ->
        :exhausted

      delay when is_integer(delay) and delay >= 0 ->
        RealtimeTelemetry.reconnect(telemetry_meta(state), state.reconnect_attempts)
        notify(state.companion, %{type: "state", state: "reconnecting"})
        # The reconnect opens a fresh server-side conversation that never issued
        # the outstanding call_ids, so abandon any in-flight tool tasks here
        # rather than let a late result fire at (or tear down) the new session.
        # The screen feed is suspended for the same reason — its frames and their
        # item ids belong to the conversation that is going away — but flagged to
        # resume, so the operator does not have to re-ask after a blip.
        state = state |> cancel_pending_tool_calls() |> suspend_screen_feed()
        # A socket death can produce BOTH a disconnect notice and an EXIT, so
        # cancel any timer already armed rather than stack a second attempt on top
        # of the first.
        if is_reference(state.reconnect_timer), do: Process.cancel_timer(state.reconnect_timer)
        timer = Process.send_after(self(), :reconnect_attempt, delay)

        {:ok,
         %{
           state
           | openai_pid: nil,
             # The provider is NOT ready while reconnecting; leaving this true let
             # readiness-gated work (screen frames) believe it had a live session.
             provider_ready?: false,
             reconnect_timer: timer,
             reconnect_attempts: state.reconnect_attempts + 1
         }}
    end
  end

  defp attempt_reconnect(state) do
    case open_openai_session(state) do
      {:ok, openai_pid, state} -> resume_provider_session(state, openai_pid)
      {:error, reason} -> {:error, reason, state}
    end
  end

  # A socket that opened but could not be configured is CLOSED before the next
  # attempt: leaving it open leaks a billed upstream connection per retry, and its
  # later EXIT would race the attempt that replaced it.
  defp resume_provider_session(state, openai_pid) do
    case send_provider_event(state.openai_client, openai_pid, state.session_update_event) do
      :ok ->
        {:ok, openai_pid, state}

      {:error, reason} ->
        state.openai_client.close(openai_pid)
        {:error, reason, state}
    end
  end

  # The ONE terminal transition. A call that has lost its provider connection for
  # good owns nothing worth keeping, so it ENDS: `terminate/2` releases the socket,
  # the screen feed, the in-flight tool tasks and the computer-use session, and the
  # socket handler's monitor tells the companion the call is over.
  #
  # This exists because the old teardown returned STATE. That left a session alive
  # with `openai_pid: nil` — and since both reconnect clauses are guarded on the
  # very fields the teardown nils, every later disconnect/EXIT was swallowed. The
  # call then streamed audio into a void indefinitely while the companion sat on
  # its last frame (observed: 43 s, ended only by the operator). The fix is not to
  # detect that state — it is to make it unrepresentable.
  defp end_call(state, reason) when is_atom(reason) do
    notify(state.companion, %{type: "error", reason: Atom.to_string(reason)})
    RealtimeTelemetry.call_stop(telemetry_meta(state), usage_measurements(state.usage), reason)
    {:stop, {:shutdown, reason}, state}
  end

  # A tool task belongs to the provider connection whose call it answers. When
  # that connection is lost — teardown (drop_session), reconnect (a fresh
  # server-side conversation the old call_id is unknown to), or process exit
  # (terminate/2) — the result is undeliverable, so brutal-kill the in-flight
  # tasks and forget them. `Task.shutdown` also flushes each task's stale reply
  # and :DOWN from the mailbox, so no late `{ref, result}` lingers.
  defp cancel_pending_tool_calls(%{pending_tool_calls: pending} = state)
       when map_size(pending) == 0,
       do: state

  defp cancel_pending_tool_calls(%{pending_tool_calls: pending} = state) do
    Enum.each(pending, fn {_ref, {task, _call}} -> Task.shutdown(task, :brutal_kill) end)
    %{state | pending_tool_calls: %{}}
  end

  defp maybe_send_truncate(_openai_pid, _state, nil), do: :ok

  defp maybe_send_truncate(_openai_pid, %{current_item_id: nil}, _audio_end_ms), do: :ok

  defp maybe_send_truncate(openai_pid, %{current_item_id: item_id} = state, audio_end_ms)
       when is_binary(item_id) and is_integer(audio_end_ms) and audio_end_ms >= 0 do
    send_provider_event(
      state.openai_client,
      openai_pid,
      OpenAIClient.truncate_item_event(item_id, audio_end_ms)
    )
  end

  defp realtime_runtime(opts, prompt_loader, capability_registry, _skill_registry)
       when is_function(prompt_loader, 1) do
    capabilities =
      Keyword.get_lazy(opts, :capabilities, fn ->
        default_capabilities(capability_registry)
      end)

    {:ok,
     %{
       available_skills: [],
       context: nil,
       profile: nil,
       capabilities: capabilities
     }}
  end

  defp realtime_runtime(_opts, nil, capability_registry, skill_registry) do
    available_skills = load_available_skills(skill_registry)

    with {:ok, context} <-
           RuntimeContext.build(
             agent_id: MemoryConfig.agent_id(),
             available_skills: available_skills,
             capability_registry: capability_registry,
             # REALTIME.md holds every voice rule there is — speech length, pacing,
             # act-in-silence. Without this flag `BootstrapLoader.load_realtime/2`
             # returns nil and `PromptComposer` drops the part, so a voice call runs
             # on the TEXT prompt alone. That is what happened in production from
             # 2026-05-23 (when the `prompt_loader` default that carried the flag was
             # removed) until 2026-07-26: four rounds of prompt fixes went to a file
             # nothing read. Only the injected-loader clause below had it.
             realtime?: true
           ) do
      profile =
        RuntimeContext.build_profile(:operator, available_skills, capability_registry,
          # `:media` too — image/video generation egresses through a channel
          # `reply_fn`, which a voice session does not have (M15 §411).
          # `:delegation` too — voice gains honest `:operator` trust, so
          # `subagents` would become executable, but a multi-minute blocking
          # fan-out does not fit a live voice session.
          excluded_categories: [:channel, :media, :delegation]
        )

      {:ok,
       %{
         available_skills: available_skills,
         context: context,
         profile: profile,
         # Realtime has no tool_call bridge-unwrap path, so it advertises the
         # FULL dispatchable surface to the OpenAI Realtime API (no deferral
         # for voice) — deferred plugin/MCP tools stay invokable (M10 P2 fix).
         capabilities: Map.get(profile, :dispatchable, profile.capabilities)
       }}
    end
  end

  defp realtime_runtime(_opts, prompt_loader, _capability_registry, _skill_registry) do
    {:error, {:invalid_prompt_loader, prompt_loader}}
  end

  defp load_available_skills(skill_registry) do
    case safe_skill_registry_call(fn -> SkillRegistry.list_detailed(skill_registry) end) do
      {:ok, skills} -> skills
      {:error, _reason} -> []
    end
  end

  defp prompt_opts(state) do
    [
      agent_id: MemoryConfig.agent_id(),
      available_skills: state.available_skills,
      runtime_capabilities: state.capabilities,
      realtime?: true
    ]
  end

  defp session_instructions(%{prompt_loader: loader} = state) when is_function(loader, 1) do
    with {:ok, prompt} <- loader.(prompt_opts(state)) do
      {:ok, prompt.messages |> Enum.map_join("\n\n", & &1.content)}
    end
  end

  defp session_instructions(%{runtime_context: %RuntimeContext{} = ctx, runtime_profile: profile}) do
    instructions =
      ctx.base_messages
      |> Kernel.++([profile.runtime_message])
      |> Enum.map_join("\n\n", & &1.content)

    {:ok, instructions}
  end

  defp session_instructions(_state), do: {:error, :runtime_context_unavailable}

  defp handle_provider_event_internal({:audio_delta, item_id, audio}, state) do
    notify(state.companion, %{type: "state", state: "speaking"})
    notify(state.companion, %{type: "audio_delta", audio: audio})

    case item_id do
      id when is_binary(id) -> %{state | current_item_id: id}
      _other -> state
    end
  end

  defp handle_provider_event_internal({:assistant_transcript_delta, text}, state) do
    notify(state.companion, %{type: "assistant_text_delta", text: text})
    %{state | assistant_transcript: state.assistant_transcript <> text}
  end

  defp handle_provider_event_internal({:user_transcript_done, text}, state) do
    notify(state.companion, %{type: "transcript_delta", role: "user", text: text})
    %{state | user_transcript: text}
  end

  defp handle_provider_event_internal({:session_created, _event}, state) do
    RealtimeTelemetry.session_created(telemetry_meta(state))
    state
  end

  defp handle_provider_event_internal(
         {:session_updated, _event},
         %{provider_ready?: true} = state
       ),
       do: state

  defp handle_provider_event_internal({:session_updated, _event}, state) do
    RealtimeTelemetry.session_updated(telemetry_meta(state))

    state
    |> Map.put(:provider_ready?, true)
    |> start_timers()
    |> notify_listening_state()
    |> resume_screen_feed()
  end

  # The provider COMMITTED the operator's speech as a turn — the conversation has
  # moved on, so anything still in the companion's playback buffer belongs to the
  # exchange before it and must not keep talking over the answer to come.
  #
  # This is the barge-in gap. Cancelling an in-flight response was already handled,
  # but the Realtime API streams audio FASTER than realtime, so a long reply is often
  # fully delivered — and therefore uncancellable — before the operator even starts
  # speaking. Nothing then flushed the buffer: the pet played the old reply to the
  # end and only afterwards answered what had been said over it (observed live).
  # A commit is the provider's own decision, so acting on it cannot cut a reply off
  # for a noise the way `speech_started` would.
  defp handle_provider_event_internal({:input_audio_committed, _event}, state) do
    notify(state.companion, %{type: "playback_stop"})
    state
  end

  # Speech boundaries drive the feed's cadence: tighten it while the operator is
  # mid-utterance so the frame they are talking ABOUT is current, relax it after.
  # Deliberately does NOT stop playback: with full duplex the mic stays open through
  # the assistant's speech, and mere DETECTION is not an interruption — a cough or a
  # backchannel "mm-hmm" must not cut a reply off. The provider decides, and the two
  # places that decision surfaces are handled: a cancelled `response.done`
  # (`maybe_notify_cancelled_response/2`) and a committed user turn
  # (`:input_audio_committed` below).
  defp handle_provider_event_internal({:input_audio_speech_started, _event}, state) do
    set_screen_feed_speaking(state, true)
  end

  defp handle_provider_event_internal({:input_audio_speech_stopped, _event}, state) do
    unless is_binary(state.current_item_id) do
      notify(state.companion, %{type: "state", state: "thinking"})
    end

    set_screen_feed_speaking(state, false)
  end

  defp handle_provider_event_internal({:assistant_transcript_done, text}, state) do
    notify(state.companion, %{type: "assistant_text_delta", text: text})
    %{state | assistant_transcript: text}
  end

  defp handle_provider_event_internal({:function_call, call}, state) do
    notify(state.companion, %{type: "tool_event", status: "running", name: tool_name(call)})

    if tool_name(call) == ScreenShare.tool_name(),
      do: run_screen_share_call(call, state),
      else: dispatch_tool_call(call, state)
  end

  defp handle_provider_event_internal({:response_created, _event}, state) do
    %{state | response_started_ms: System.monotonic_time(:millisecond)}
  end

  defp handle_provider_event_internal({:response_done, response}, state) do
    state
    |> maybe_emit_provider_call(response)
    |> maybe_notify_cancelled_response(response)
    |> Map.put(:current_item_id, nil)
    |> notify_listening_state()
    |> maybe_apply_reported_usage(response)
    |> maybe_record_exchange()
  end

  defp handle_provider_event_internal({:error, error}, state) do
    if active_response_race?(error) do
      handle_active_response_race(error, state)
    else
      # Reported, not fatal. If the error is genuinely terminal OpenAI closes the
      # socket and the disconnect/EXIT clauses handle it as the one reconnect path;
      # tearing down here instead disarmed that path.
      Logger.warning("OpenAI Realtime error: #{inspect(error)}")
      RealtimeTelemetry.provider_error(telemetry_meta(state), reason_to_string(error))
      notify(state.companion, %{type: "error", reason: reason_to_string(error)})
      state
    end
  end

  defp handle_provider_event_internal({:unhandled, type, _event}, state) do
    Logger.debug("Unhandled OpenAI Realtime event: #{type}")
    state
  end

  defp handle_provider_event_internal(_event, state), do: state

  # Run the tool OFF the session loop (async_nolink on the Realtime task
  # supervisor). A multi-second tool used to block this GenServer's mailbox,
  # starving `audio_chunk`/`interrupt` and wedging the whole call. The result
  # comes back as `{ref, result}` (or `:DOWN` on crash) and is answered there.
  defp dispatch_tool_call(call, state) do
    bridge = state.tool_bridge

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        ToolBridge.execute_call(bridge, call)
      end)

    %{state | pending_tool_calls: Map.put(state.pending_tool_calls, task.ref, {task, call})}
  end

  # `screen_share` is answered INLINE rather than on the task supervisor: starting
  # the feed is a non-blocking hand-off (the feed's own continue does the sidecar
  # work), and the reply must be built from — and mutate — this session's state.
  #
  # It still emits through the SHARED tool emitter: answering inline is an
  # implementation detail, and a verb the model calls must appear in traces like
  # every other tool. (It did not, and a live debug had to infer a stop from the
  # feed's lifecycle event alone.)
  defp run_screen_share_call(call, state) do
    started_ms = System.monotonic_time(:millisecond)
    args = call_arguments(call)

    {state, outcome} =
      case ScreenShare.decode(args) do
        {:ok, :start, display} -> start_screen_share(call, display, state)
        {:ok, :stop, _display} -> stop_screen_share(call, state)
        {:error, reason} -> {answer_tool_error(call, reason, state), {:error, reason}}
      end

    emit_screen_share_telemetry(state, args, outcome, started_ms)
    state
  end

  defp emit_screen_share_telemetry(state, args, outcome, started_ms) do
    ToolsTelemetry.exec(
      ScreenShare.tool_name(),
      state.tool_context,
      match?({:ok, _}, outcome),
      max(0, System.monotonic_time(:millisecond) - started_ms),
      input: args,
      output: screen_share_output(outcome),
      metadata: %{action: Map.get(args, "action")}
    )
  end

  defp screen_share_output({:ok, payload}), do: payload
  defp screen_share_output({:error, reason}), do: %{error: reason_to_string(reason)}

  defp start_screen_share(call, _display, %{screen_feed: pid} = state) when is_pid(pid) do
    answer_tool_ok(call, %{status: "already_sharing", display: state.screen_display}, state)
  end

  defp start_screen_share(call, display, state) do
    with :ok <-
           ScreenShare.gate(state.config, screen_share_origin(state), probe: state.screen_probe),
         {:ok, state} <- open_screen_feed(state, display) do
      answer_tool_ok(
        call,
        %{status: "sharing", display: display, note: ScreenShare.started_text(display)},
        state
      )
    else
      {:error, reason} -> {answer_tool_error(call, reason, state), {:error, reason}}
    end
  end

  defp stop_screen_share(call, %{screen_feed: pid} = state) when is_pid(pid) do
    answer_tool_ok(call, %{status: "stopped"}, close_screen_feed(state, :requested))
  end

  defp stop_screen_share(call, state) do
    answer_tool_ok(call, %{status: "not_sharing"}, state)
  end

  defp open_screen_feed(state, display) do
    opts =
      state.screen_feed_opts
      |> Keyword.put(:owner, self())
      |> Keyword.put(:display, display)

    case state.screen_feed_module.start_link(opts) do
      {:ok, pid} ->
        RealtimeTelemetry.screen_feed_start(telemetry_meta(state), display)
        # Deliberately NO companion `state` frame. The wire's state vocabulary is
        # closed and the companion maps anything it does not know to `idle`, so a
        # "sharing_screen" state made the pet look like the call had ENDED the
        # instant sharing began. A visible sharing indicator needs a real protocol
        # addition and a paired app release (§10 non-goal), not an invented value.
        {:ok, %{state | screen_feed: pid, screen_display: display}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Stop the feed and forget its frames: the item ids are provider state, so they
  # are meaningless once this feed (or this provider connection) is gone. Keeping
  # `screen_share_resume?` separate is what lets a reconnect re-open the feed
  # without the model asking twice.
  defp close_screen_feed(%{screen_feed: pid} = state, reason) when is_pid(pid) do
    state.screen_feed_module.stop(pid, reason)
    %{state | screen_feed: nil, screen_frame_items: []}
  end

  defp close_screen_feed(state, _reason), do: %{state | screen_frame_items: []}

  # A provider connection is going away (teardown OR a transient blip before a
  # reconnect). Either way the frames in flight belong to a conversation that will
  # not exist afterwards, so the feed stops; `resume?` remembers that the operator
  # asked for sharing so `session.updated` can re-open it.
  defp suspend_screen_feed(%{screen_feed: pid} = state) when is_pid(pid) do
    %{close_screen_feed(state, :requested) | screen_share_resume?: true}
  end

  defp suspend_screen_feed(state), do: state

  defp resume_screen_feed(%{screen_share_resume?: true, screen_feed: nil} = state) do
    state = %{state | screen_share_resume?: false}

    case open_screen_feed(state, state.screen_display || 0) do
      {:ok, state} ->
        state

      {:error, reason} ->
        Logger.warning("realtime: screen feed did not resume after reconnect: #{inspect(reason)}")
        inject_screen_notice(state, ScreenShare.stopped_text({:capture_unavailable, reason}))
    end
  end

  defp resume_screen_feed(state), do: state

  defp screen_share_origin(state), do: Map.get(state.tool_context, :computer_use_origin, :voice)

  # Frames are QUEUED, never sent with the blocking call the rest of the session
  # uses. A frame is bulk, periodic, and disposable: waiting on it froze the call
  # (no audio, no events) and, on the 5s deadline, tore it down. Dropping one is
  # invisible — another is ~2s away — so the only correct failure here is to skip.
  defp append_screen_frame(%{provider_ready?: false} = state, _frame) do
    Logger.debug("realtime: dropped a screen frame with no ready provider session")
    state
  end

  defp append_screen_frame(%{openai_pid: pid} = state, frame) when is_pid(pid) do
    if state.openai_client.pending_sends(pid) > @max_pending_sends do
      # The socket is behind. Queueing anyway would just move an unbounded backlog
      # into its mailbox; the newest frame wins and this one is stale already.
      RealtimeTelemetry.frame_dropped(telemetry_meta(state), frame.bytes)
      state
    else
      queue_screen_frame(state, pid, frame)
    end
  end

  defp append_screen_frame(state, _frame), do: state

  defp queue_screen_frame(state, pid, frame) do
    item_id = mint_frame_item_id()
    {retained, evicted} = Enum.split([item_id | state.screen_frame_items], @frames_retained)

    events =
      [OpenAIClient.screen_frame_item_event(item_id, frame, @frame_detail)] ++
        Enum.map(evicted, &OpenAIClient.delete_item_event/1)

    Enum.each(events, &state.openai_client.cast_event(pid, &1))

    RealtimeTelemetry.frame_sent(
      telemetry_meta(state),
      frame.bytes,
      frame.gated_out,
      @frame_detail
    )

    %{state | screen_frame_items: retained}
  end

  # A client-assigned id, so a superseded frame can be evicted by id later without
  # having to correlate the server's `conversation.item.created` back to a frame.
  defp mint_frame_item_id do
    "item_fx" <> Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
  end

  defp note_screen_feed_stopped(state, reason, measurements) do
    RealtimeTelemetry.screen_feed_stop(
      telemetry_meta(state),
      reason_to_string(reason),
      measurements
    )

    state = %{state | screen_feed: nil, screen_frame_items: []}

    # An operator-requested stop was already answered by the tool result. Any other
    # reason means the model's eyes closed WITHOUT it asking, so it must be told —
    # otherwise it keeps narrating a screen it can no longer see.
    if reason == :requested,
      do: state,
      else: inject_screen_notice(state, ScreenShare.stopped_text(reason))
  end

  # Fermix's own status text, injected as passive context (no `response.create`):
  # the model picks it up on its next turn instead of interrupting the operator.
  defp inject_screen_notice(state, text) do
    case send_openai_seq(state, [OpenAIClient.status_item_event(text)]) do
      :ok ->
        state

      {:error, reason} ->
        Logger.debug("realtime: could not inject screen notice: #{inspect(reason)}")
        state
    end
  end

  defp set_screen_feed_speaking(%{screen_feed: pid} = state, speaking?) when is_pid(pid) do
    state.screen_feed_module.set_speaking(pid, speaking?)
    state
  end

  defp set_screen_feed_speaking(state, _speaking?), do: state

  # The feed spends a fixed share of the call's ONE budget. It stops first and the
  # call continues: losing the eyes is recoverable and audible, ending the call is
  # neither.
  defp enforce_feed_budget(%{screen_feed: pid} = state) when is_pid(pid) do
    if CostTracker.feed_over_budget?(state.usage),
      do: close_screen_feed(state, :cost),
      else: state
  end

  defp enforce_feed_budget(state), do: state

  # Returns `{state, outcome}` so the caller emits one honest tool span for the
  # verb it just answered.
  defp answer_tool_ok(call, payload, state) do
    state =
      apply_tool_result(
        {:ok, %{call_id: call_id(call), output: Jason.encode!(payload)}},
        call,
        state
      )

    {state, {:ok, payload}}
  end

  defp answer_tool_error(call, reason, state) do
    apply_tool_result({:error, %{call_id: call_id(call), reason: reason}}, call, state)
  end

  defp call_arguments(call) do
    case Jason.decode(Map.get(call, "arguments") || Map.get(call, :arguments) || "{}") do
      {:ok, %{} = args} -> args
      _other -> %{}
    end
  end

  defp apply_tool_result({:ok, output}, call, state) do
    state = send_openai_events(state, OpenAIClient.function_output_events(output, state.config))
    notify(state.companion, %{type: "tool_event", status: "completed", name: tool_name(call)})
    state
  end

  defp apply_tool_result({:error, %{call_id: call_id, reason: reason}}, call, state) do
    output = %{call_id: call_id, output: Jason.encode!(%{error: reason_to_string(reason)})}
    state = send_openai_events(state, OpenAIClient.function_output_events(output, state.config))

    notify(state.companion, %{
      type: "tool_event",
      status: "error",
      name: tool_name(call),
      reason: reason_to_string(reason)
    })

    state
  end

  defp handle_active_response_race(error, state) do
    Logger.debug("Ignoring OpenAI Realtime active-response race: #{inspect(error)}")
    state
  end

  defp close_openai(%{openai_pid: pid, openai_client: client}) when is_pid(pid),
    do: client.close(pid)

  defp close_openai(_state), do: :ok

  defp audio_duration_ms(audio) do
    max(1, div(byte_size(audio) + @pcm16_bytes_per_ms - 1, @pcm16_bytes_per_ms))
  end

  defp notify(pid, event) when is_pid(pid), do: send(pid, {:realtime, event})

  # Deliberately does NOT send the companion an `error` frame: the pet treats that
  # as terminal (it shuts the microphone down and clears `callActive`), which is
  # the wrong response to one dropped event on a call that is still live. The
  # operator learns about a real loss through the reconnect/terminal path instead.
  # A call that never connected: the companion must hear it, because there is no
  # connection owner to recover and no call to keep alive.
  defp notify_call_start_error(state, reason) do
    notify(state.companion, %{
      type: "error",
      reason: "provider_send_failed: #{reason_to_string(reason)}"
    })
  end

  defp report_provider_send_error(state, reason) do
    Logger.warning("realtime: provider send failed: #{reason_to_string(reason)}")
    RealtimeTelemetry.provider_error(telemetry_meta(state), reason_to_string(reason))
    state
  end

  defp send_openai(%{openai_pid: pid, openai_client: client}, event) when is_pid(pid) do
    send_provider_event(client, pid, event)
  end

  defp send_openai(_state, _event), do: {:error, :provider_not_connected}

  # A send that fails is REPORTED, never fatal. Connection liveness has exactly one
  # owner — the socket's disconnect/EXIT clauses — and this used to be a second,
  # contradictory one: a failed send tore the session down, nilling the very fields
  # those clauses match on, so the reconnect that should have followed was
  # swallowed. If the socket really is gone its own signal arrives and reconnects;
  # if the payload was bad, ending the call would not have helped.
  defp send_openai_events(state, events) do
    case send_openai_seq(state, events) do
      :ok -> state
      {:error, reason} -> report_provider_send_error(state, reason)
    end
  end

  defp send_openai_seq(state, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case send_openai(state, event) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp notify_listening_state(state) do
    notify(state.companion, %{type: "state", state: "listening"})
    state
  end

  defp send_provider_event(client, pid, event) when is_pid(pid) and is_map(event) do
    client.send_event(pid, event)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp require_binary(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_value, name), do: {:error, {:missing, name}}

  defp default_capabilities(capability_registry) do
    # Realtime keeps parity with Main Agent except for channel-only reply tools,
    # which need an active channel reply function that voice sessions do not have.
    # The prior `tool_policy = "read_only"`/`"broad"` knob was a defensive
    # default against an always-listening voice threat model that never
    # shipped (M9.1 is click-to-talk only); it had the side effect of
    # hiding MCP and skill capabilities from voice. Removed in favor of
    # parity with text. Operators wanting a restricted voice surface tune
    # sandbox mode + command profile instead — both apply uniformly.
    # Voice is the operator at the keyboard — same trust level as the
    # human owner messaging from CLI or a remote channel. Declared
    # explicitly at the call site rather than inferred from absence.
    CapabilityRegistry.list_for(capability_registry,
      trust: :operator,
      # `:media` too — generation egresses through a channel `reply_fn` a voice
      # session lacks (M15 §411). `:delegation` too — `subagents` would be
      # executable at the session's honest `:operator` trust, but a multi-minute
      # blocking fan-out does not fit a live voice session. Kept in sync with the
      # profile above.
      excluded_categories: [:channel, :media, :delegation]
    )
  end

  defp safe_skill_registry_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:error, reason}
  end

  defp maybe_apply_reported_usage(state, %{"usage" => %{} = usage} = response) do
    # Accumulated per response and deduplicated by response id: a call has many
    # responses, and retained screen frames are re-read by each one.
    tracker = CostTracker.add_reported_usage(state.usage, Map.get(response, "id"), usage)

    notify(state.companion, %{
      type: "usage",
      status: "reported",
      cost_cents: tracker.reported.cost_cents
    })

    enforce_feed_budget(%{state | usage: tracker})
  end

  defp maybe_apply_reported_usage(state, _response), do: state

  # The realtime model turn has no provider adapter, so emit it once through the
  # shared provider emitter when usage is present: one provider.call per
  # response.done → llm_call JSONL → Opik LLM span. The real model id lets Opik
  # price it; tool calls already self-emit via the tool emitter on the same
  # session_id (no wrapper here — that would double-emit).
  defp maybe_emit_provider_call(state, %{"usage" => usage})
       when is_map(usage) and map_size(usage) > 0 do
    ProviderTelemetry.emit_call(
      %{
        provider: :openai,
        model: state.config.model,
        status: :ok,
        agent: "realtime",
        tokens: tokens_from_usage(usage)
      },
      response_duration_ms(state),
      session_id: to_string(state.session_scope),
      input: transcript_or_nil(state.user_transcript),
      output: transcript_or_nil(state.assistant_transcript)
    )

    %{state | response_started_ms: nil}
  end

  defp maybe_emit_provider_call(state, _response), do: state

  # The realtime turn's transcripts are the LLM span's input/output. emit_call
  # gates them behind `capture_content?/0`; an empty transcript becomes nil so a
  # blank preview never rides the event. Emitted before `maybe_record_exchange`
  # clears the transcripts (see the response_done pipeline).
  defp transcript_or_nil(""), do: nil
  defp transcript_or_nil(text) when is_binary(text), do: text

  # `cached` rides alongside the totals because the split is what the session's own
  # cost accounting turns on, and it was NOT recoverable after the fact: a call that
  # tripped the cost ceiling could not be audited from its trace, only re-derived by
  # arithmetic. A cached token costs a tenth of an uncached one, and a Realtime call
  # re-sends its whole preamble every response, so this is most of the bill.
  defp tokens_from_usage(usage) do
    prompt = non_neg_int(Map.get(usage, "input_tokens"))
    completion = non_neg_int(Map.get(usage, "output_tokens"))

    cached =
      usage |> Map.get("input_token_details", %{}) |> Map.get("cached_tokens") |> non_neg_int()

    %{prompt: prompt, completion: completion, total: prompt + completion, cached: cached}
  end

  defp non_neg_int(value) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_value), do: 0

  defp response_duration_ms(%{response_started_ms: started}) when is_integer(started) do
    max(0, System.monotonic_time(:millisecond) - started)
  end

  defp response_duration_ms(_state), do: 0

  defp telemetry_meta(state) do
    %{
      session_id: to_string(state.session_scope),
      device_id: state.device_id,
      model: state.config.model,
      voice: state.config.voice,
      session_scope: to_string(state.session_scope)
    }
  end

  # The call's accumulated usage, carried on the `call_stop` lifecycle event so
  # the trace keeps the session's audio footprint instead of dropping it at
  # teardown. Measurements are numeric only (telemetry contract), so cost rides
  # as cents floats; Opik still auto-prices the per-turn LLM spans separately.
  defp usage_measurements(%CostTracker{estimated: estimated, reported: reported}) do
    %{
      input_audio_ms: estimated.input_audio_ms,
      input_audio_tokens: estimated.input_audio_tokens,
      estimated_cost_cents: estimated.cost_cents,
      reported_cost_cents: reported.cost_cents
    }
  end

  defp start_timers(state) do
    state
    |> cancel_timers()
    |> Map.put(
      :max_session_timer,
      Process.send_after(
        self(),
        :max_session_duration,
        state.config.max_session_minutes * @minute_ms
      )
    )
  end

  defp cancel_timers(state) do
    if is_reference(state.max_session_timer), do: Process.cancel_timer(state.max_session_timer)
    if is_reference(state.reconnect_timer), do: Process.cancel_timer(state.reconnect_timer)
    %{state | max_session_timer: nil, reconnect_timer: nil}
  end

  defp notify_usage(state, status) do
    notify(state.companion, %{
      type: "usage",
      status: status,
      estimated: state.usage.estimated,
      reported: state.usage.reported
    })
  end

  defp maybe_notify_cancelled_response(state, response) do
    if cancelled_response?(response) do
      notify(state.companion, %{type: "playback_stop"})
    end

    state
  end

  defp cancelled_response?(%{"status" => "cancelled"}), do: true
  defp cancelled_response?(%{status: "cancelled"}), do: true
  defp cancelled_response?(%{"status_details" => %{"type" => "cancelled"}}), do: true
  defp cancelled_response?(%{status_details: %{type: "cancelled"}}), do: true
  defp cancelled_response?(_response), do: false

  defp active_response_race?(%{code: "conversation_already_has_active_response"}), do: true

  defp active_response_race?(%{"code" => "conversation_already_has_active_response"}),
    do: true

  defp active_response_race?(_error), do: false

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(%{code: code}) when is_binary(code), do: code
  defp reason_to_string(%{"code" => code}) when is_binary(code), do: code
  defp reason_to_string(%{message: message}) when is_binary(message), do: message
  defp reason_to_string(%{"message" => message}) when is_binary(message), do: message
  defp reason_to_string(%{reason: reason}), do: reason_to_string(reason)
  defp reason_to_string(%{"reason" => reason}), do: reason_to_string(reason)

  defp reason_to_string(%{__struct__: module} = reason) when module != nil do
    if function_exported?(module, :message, 1),
      do: Exception.message(reason),
      else: inspect(reason)
  end

  defp reason_to_string(reason), do: inspect(reason)

  defp maybe_record_exchange(%{config: %{persist_transcripts?: false}} = state),
    do: clear_transcripts(state)

  defp maybe_record_exchange(state) do
    opts =
      state.recorder_opts
      |> Keyword.put_new(:session_scope, state.session_scope)
      |> Keyword.put_new(:usage, state.usage)

    case state.recorder_module.record_exchange(
           state.config,
           state.device_id,
           state.user_transcript,
           state.assistant_transcript,
           opts
         ) do
      :ok ->
        clear_transcripts(state)

      {:error, reason} ->
        notify(state.companion, %{
          type: "error",
          reason: reason_to_string({:transcript_persist_failed, reason})
        })

        clear_transcripts(state)
    end
  end

  defp clear_transcripts(state), do: %{state | user_transcript: "", assistant_transcript: ""}

  defp default_context(device_id) do
    %{
      agent_name: "realtime",
      conversation_key: ConversationRecorder.conversation_key(device_id),
      memory_agent_id: MemoryConfig.agent_id(),
      memory_owner_id: MemoryConfig.owner_id(),
      realtime?: true,
      # Voice is the operator at the keyboard — the session already builds its
      # capability surface at `trust: :operator`, so the tool context carries the
      # same trust rather than a nil that trust-asserting writers (e.g.
      # `schedule_job`) would reject. Not new privilege; the context stops lying.
      source_trust: :operator
    }
  end

  defp tool_name(%{"name" => name}), do: name
  defp tool_name(%{name: name}), do: name
  defp tool_name(_call), do: "unknown"

  defp call_id(call), do: Map.get(call, "call_id") || Map.get(call, :call_id) || ""
end
