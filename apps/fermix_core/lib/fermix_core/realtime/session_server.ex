defmodule FermixCore.Realtime.SessionServer do
  @moduledoc """
  Owns one local full-duplex Realtime voice call.
  """

  use GenServer

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.ComputerUse.SessionManager, as: ComputerUseSessionManager
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.ConversationRecorder
  alias FermixCore.Realtime.CostTracker
  alias FermixCore.Realtime.OpenAIClient
  alias FermixCore.Realtime.Telemetry, as: RealtimeTelemetry
  alias FermixCore.Realtime.ToolBridge

  require Logger

  @pcm16_bytes_per_ms 48
  @minute_ms 60_000
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

  @spec audio_chunk(GenServer.server(), binary()) :: :ok | {:error, term()}
  def audio_chunk(server, audio) when is_binary(audio),
    do: GenServer.call(server, {:audio_chunk, audio})

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
           response_started_ms: nil
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
          notify_provider_send_error(state, reason)
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        notify_provider_send_error(state, reason)
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

  def handle_call({:audio_chunk, _audio}, _from, %{muted?: true} = state) do
    {:reply, {:error, :muted}, state}
  end

  def handle_call({:audio_chunk, audio}, _from, %{openai_pid: openai_pid} = state)
      when is_pid(openai_pid) do
    case send_openai(state, OpenAIClient.audio_append_event(audio)) do
      :ok ->
        usage = CostTracker.add_input_audio_ms(state.usage, audio_duration_ms(audio))
        state = %{state | usage: usage}

        notify_usage(state, "estimated")

        case CostTracker.enforce_limits(usage) do
          :ok ->
            {:reply, :ok, state}

          {:stop, reason} ->
            notify(state.companion, %{
              type: "usage",
              status: "limit_reached",
              reason: Atom.to_string(reason)
            })

            {:reply, {:error, reason}, drop_session(state)}
        end

      {:error, reason} ->
        notify_provider_send_error(state, reason)
        {:reply, {:error, reason}, drop_session(state)}
    end
  end

  def handle_call({:audio_chunk, _audio}, _from, state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:interrupt, audio_end_ms}, _from, %{openai_pid: openai_pid} = state)
      when is_pid(openai_pid) do
    with :ok <- maybe_send_truncate(openai_pid, state, audio_end_ms),
         :ok <- send_openai(state, OpenAIClient.cancel_response_event()) do
      notify(state.companion, %{type: "playback_stop"})
      notify(state.companion, %{type: "state", state: "listening"})

      {:reply, :ok, %{state | current_item_id: nil}}
    else
      {:error, reason} ->
        notify_provider_send_error(state, reason)
        {:reply, {:error, reason}, drop_session(state)}
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
    RealtimeTelemetry.call_stop(telemetry_meta(state), usage_measurements(state.usage))
    {:reply, :ok, drop_session(state)}
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
  def handle_info({:openai_realtime_event, event}, state) do
    {:noreply, handle_provider_event_internal(event, state)}
  end

  def handle_info({:openai_realtime_disconnect, _reason}, %{session_update_event: nil} = state) do
    {:noreply, state}
  end

  def handle_info({:openai_realtime_disconnect, reason}, state) do
    case schedule_reconnect(state) do
      {:ok, state} ->
        {:noreply, state}

      :exhausted ->
        notify(state.companion, %{
          type: "error",
          reason: reason_to_string({:disconnected, reason})
        })

        {:noreply, drop_session(state)}
    end
  end

  def handle_info({:openai_realtime_error, reason}, state) do
    notify(state.companion, %{type: "error", reason: reason_to_string(reason)})
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{openai_pid: pid, session_update_event: event} = state)
      when not is_nil(event) do
    case schedule_reconnect(state) do
      {:ok, state} ->
        {:noreply, state}

      :exhausted ->
        notify(state.companion, %{
          type: "error",
          reason: reason_to_string({:disconnected, reason})
        })

        {:noreply, drop_session(state)}
    end
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
            notify(state.companion, %{type: "error", reason: "reconnect_failed"})
            {:noreply, drop_session(state)}
        end
    end
  end

  def handle_info(:max_session_duration, state) do
    notify(state.companion, %{type: "error", reason: "max_session_duration"})
    {:noreply, drop_session(state)}
  end

  @impl true
  def terminate(_reason, %{tool_context: context}) do
    # Backstop for the §7.6 guarantee on any process exit (crash, supervisor
    # shutdown, disconnect) that never reached `:call_stop`: never let a host
    # computer-use session outlive the attended voice call. Idempotent — a no-op
    # when the model didn't use computer-use this call.
    ComputerUseSessionManager.abort(context)
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
      tools = ToolBridge.to_openai_tools(state.capabilities)
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
        timer = Process.send_after(self(), :reconnect_attempt, delay)

        {:ok,
         %{
           state
           | openai_pid: nil,
             reconnect_timer: timer,
             reconnect_attempts: state.reconnect_attempts + 1
         }}
    end
  end

  defp attempt_reconnect(state) do
    with {:ok, openai_pid, state} <- open_openai_session(state),
         :ok <- send_provider_event(state.openai_client, openai_pid, state.session_update_event) do
      {:ok, openai_pid, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp drop_session(state) do
    # Losing the provider connection — for ANY reason: call end, max-session
    # duration, exhausted reconnect, fatal error, usage limit, even a transient
    # blip before a reconnect — means the model can no longer see or react, so a
    # host computer-use session must not persist (COMPUTER_USE.md §7.6). Tear it
    # down before dropping the socket; idempotent, and a reconnect's next action
    # re-opens a fresh session via SessionManager.ensure. `terminate/2` is the
    # backstop for a process death that never runs drop_session.
    ComputerUseSessionManager.abort(state.tool_context)
    close_openai(state)

    state
    |> cancel_timers()
    |> Map.merge(%{
      openai_pid: nil,
      session_update_event: nil,
      provider_ready?: false,
      reconnect_attempts: 0,
      reconnect_timer: nil,
      current_item_id: nil
    })
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
             capability_registry: capability_registry
           ) do
      profile =
        RuntimeContext.build_profile(:operator, available_skills, capability_registry,
          # `:media` too — image/video generation egresses through a channel
          # `reply_fn`, which a voice session does not have (M15 §411).
          excluded_categories: [:channel, :media]
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
  end

  defp handle_provider_event_internal({:input_audio_committed, _event}, state), do: state

  defp handle_provider_event_internal({:input_audio_speech_started, _event}, state), do: state

  defp handle_provider_event_internal({:input_audio_speech_stopped, _event}, state) do
    unless is_binary(state.current_item_id) do
      notify(state.companion, %{type: "state", state: "thinking"})
    end

    state
  end

  defp handle_provider_event_internal({:assistant_transcript_done, text}, state) do
    notify(state.companion, %{type: "assistant_text_delta", text: text})
    %{state | assistant_transcript: text}
  end

  defp handle_provider_event_internal({:function_call, call}, state) do
    notify(state.companion, %{type: "tool_event", status: "running", name: tool_name(call)})

    state =
      case ToolBridge.execute_call(state.tool_bridge, call) do
        {:ok, output} ->
          state =
            send_openai_events(state, OpenAIClient.function_output_events(output, state.config))

          notify(state.companion, %{
            type: "tool_event",
            status: "completed",
            name: tool_name(call)
          })

          state

        {:error, %{call_id: call_id, reason: reason}} ->
          output = %{call_id: call_id, output: Jason.encode!(%{error: reason_to_string(reason)})}

          state =
            send_openai_events(state, OpenAIClient.function_output_events(output, state.config))

          notify(state.companion, %{
            type: "tool_event",
            status: "error",
            name: tool_name(call),
            reason: reason_to_string(reason)
          })

          state
      end

    state
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
      Logger.warning("OpenAI Realtime error: #{inspect(error)}")
      RealtimeTelemetry.provider_error(telemetry_meta(state), reason_to_string(error))
      notify(state.companion, %{type: "error", reason: reason_to_string(error)})
      drop_session(state)
    end
  end

  defp handle_provider_event_internal({:unhandled, type, _event}, state) do
    Logger.debug("Unhandled OpenAI Realtime event: #{type}")
    state
  end

  defp handle_provider_event_internal(_event, state), do: state

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

  defp notify_provider_send_error(state, reason) do
    notify(state.companion, %{
      type: "error",
      reason: "provider_send_failed: #{reason_to_string(reason)}"
    })
  end

  defp send_openai(%{openai_pid: pid, openai_client: client}, event) when is_pid(pid) do
    send_provider_event(client, pid, event)
  end

  defp send_openai(_state, _event), do: {:error, :provider_not_connected}

  defp send_openai_events(state, events) do
    case send_openai_seq(state, events) do
      :ok ->
        state

      {:error, reason} ->
        notify_provider_send_error(state, reason)
        drop_session(state)
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
      # session lacks (M15 §411); kept in sync with the profile above.
      excluded_categories: [:channel, :media]
    )
  end

  defp safe_skill_registry_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:error, reason}
  end

  defp maybe_apply_reported_usage(state, %{"usage" => %{} = usage}) do
    tracker = CostTracker.put_reported_tokens(state.usage, usage)

    notify(state.companion, %{
      type: "usage",
      status: "reported",
      cost_cents: tracker.reported.cost_cents
    })

    %{state | usage: tracker}
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

  defp tokens_from_usage(usage) do
    prompt = non_neg_int(Map.get(usage, "input_tokens"))
    completion = non_neg_int(Map.get(usage, "output_tokens"))
    %{prompt: prompt, completion: completion, total: prompt + completion}
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
      realtime?: true
    }
  end

  defp tool_name(%{"name" => name}), do: name
  defp tool_name(%{name: name}), do: name
  defp tool_name(_call), do: "unknown"
end
