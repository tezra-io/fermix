defmodule FermixCore.Realtime.SessionServer do
  @moduledoc """
  Owns one local full-duplex Realtime voice call.
  """

  use GenServer

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Prompt.PromptComposer
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.ConversationRecorder
  alias FermixCore.Realtime.CostTracker
  alias FermixCore.Realtime.OpenAIClient
  alias FermixCore.Realtime.ToolBridge

  require Logger

  @pcm16_bytes_per_ms 48
  @minute_ms 60_000
  # `call_start` blocks while the upstream WebSocket handshake completes.
  # Keep this strictly above `OpenAIClient.handshake_timeout_ms/0` so an
  # upstream stall surfaces as a WebSockex timeout, not a GenServer.call exit.
  @call_start_timeout_ms 10_000
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

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = Keyword.get_lazy(opts, :config, &Config.current/0)
    capabilities = Keyword.get_lazy(opts, :capabilities, fn -> default_capabilities(config) end)
    device_id = Keyword.get(opts, :device_id, "unknown")
    context = Keyword.get_lazy(opts, :context, fn -> default_context(device_id) end)

    {:ok,
     %{
       companion: Keyword.fetch!(opts, :companion),
       config: config,
       device_id: device_id,
       session_scope: Keyword.get(opts, :session_scope, :root),
       openai_client: Keyword.get(opts, :openai_client, OpenAIClient),
       openai_pid: nil,
       api_key: Keyword.get(opts, :api_key),
       safety_identifier: Keyword.get(opts, :safety_identifier),
       capabilities: capabilities,
       tool_bridge: ToolBridge.new(capabilities, context),
       prompt_loader: Keyword.get(opts, :prompt_loader, &PromptComposer.compose_with_metadata/1),
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
       current_item_id: nil
     }}
  end

  @impl true
  def handle_call(:call_start, _from, %{session_update_event: nil} = state) do
    with {:ok, openai_pid, state} <- open_openai_session(state),
         {:ok, event} <- build_session_update_event(state) do
      case send_provider_event(state.openai_client, openai_pid, event) do
        :ok ->
          notify(state.companion, %{type: "state", state: "listening"})

          state =
            %{state | openai_pid: openai_pid, session_update_event: event}
            |> start_timers()

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

  def handle_call(:call_start, _from, %{openai_pid: openai_pid} = state)
      when is_pid(openai_pid) do
    notify(state.companion, %{type: "state", state: "listening"})
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
    {:reply, :ok, drop_session(state)}
  end

  def handle_call({:provider_event, event}, _from, state) do
    {:reply, :ok, handle_provider_event_internal(event, state)}
  end

  def handle_call(:openai_pid, _from, state), do: {:reply, state.openai_pid, state}
  def handle_call(:usage, _from, state), do: {:reply, state.usage, state}

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
        notify(state.companion, %{type: "state", state: "listening"})

        {:noreply, %{state | openai_pid: openai_pid, reconnect_attempts: 0, reconnect_timer: nil}}

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
    with {:ok, prompt} <- state.prompt_loader.(prompt_opts(state)) do
      instructions = prompt.messages |> Enum.map_join("\n\n", & &1.content)
      tools = ToolBridge.to_openai_tools(state.capabilities)
      {:ok, OpenAIClient.session_update_event(state.config, instructions, tools)}
    end
  end

  defp schedule_reconnect(state) do
    case Enum.at(state.reconnect_backoff_ms, state.reconnect_attempts) do
      nil ->
        :exhausted

      delay when is_integer(delay) and delay >= 0 ->
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
    close_openai(state)

    state
    |> cancel_timers()
    |> Map.merge(%{
      openai_pid: nil,
      session_update_event: nil,
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

  defp prompt_opts(state) do
    [
      agent_id: MemoryConfig.agent_id(),
      available_skills: [],
      runtime_capabilities: state.capabilities,
      realtime?: true
    ]
  end

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

  defp handle_provider_event_internal({:session_created, _event}, state), do: state

  defp handle_provider_event_internal({:session_updated, _event}, state), do: state

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

  defp handle_provider_event_internal({:response_created, _event}, state), do: state

  defp handle_provider_event_internal({:response_done, response}, state) do
    state
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

  defp default_capabilities(%Config{} = _config) do
    # Realtime uses the same registry view as Main Agent — no trust filter.
    # The prior `tool_policy = "read_only"`/`"broad"` knob was a defensive
    # default against an always-listening voice threat model that never
    # shipped (M9.1 is click-to-talk only); it had the side effect of
    # hiding MCP and skill capabilities from voice. Removed in favor of
    # parity with text. Operators wanting a restricted voice surface tune
    # sandbox mode + command profile instead — both apply uniformly.
    CapabilityRegistry.list(CapabilityRegistry, include_approval_required?: false)
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
