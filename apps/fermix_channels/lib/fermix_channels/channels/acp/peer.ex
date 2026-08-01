defmodule FermixChannels.Channels.Acp.Peer do
  @moduledoc """
  One ACP client connection (MILESTONE_29_ACP_AGENT_SURFACE.md §6.1) — the unit
  of ownership on this surface.

  A Peer owns its socket, its line assembly, the bridge handshake, its session
  table, and every byte written back. Sessions are plain state in this process
  (never processes), so one Peer can never touch another Peer's sessions, and a
  single process means outbound frames are naturally ordered with no writer lock.

  ## The two phases of a connection

  1. **Bridge handshake** (§6.2). The first line must be
     `{"fermix_bridge": 1, "app_version": …, "env": {…}}`, within
     `Timeouts.acp_bridge_hello/0` and under `@max_hello_bytes`. The daemon filters the env
     to the allowlist (`SessionEnv`), answers `{"fermix_bridge_ack": …}`, and
     only then speaks ACP. A refusal is written as an ack, because that is the
     only line the bridge knows how to read before it becomes a byte pump.
  2. **ACP** (§7). Every line is decoded by `Channels.Acp.Wire`; requests are
     answered, notifications acted on or ignored, and `session/prompt` becomes an
     ordinary gateway turn whose stream/tool/outcome events come back here as
     `{:acp_event, session_id, seq, payload}` messages.

  After the handshake **nothing but ACP frames** may be written — an ack line at
  that point would corrupt the client's protocol stream.

  ## The wire fence

  Every turn carries a monotonically increasing sequence (`Session`), stamped on
  the inbound message and returned on every event. The Peer writes only what
  belongs to the turn that is open right now; after a terminal response the turn
  is cleared and late events are dropped-and-logged (§8.5). Terminal responses
  are therefore exactly one per prompt: the response clears the fence that would
  admit a second one.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixChannels.Channels.Acp
  alias FermixChannels.Channels.Acp.Session
  alias FermixChannels.Channels.Acp.SessionEnv
  alias FermixChannels.Channels.Acp.Wire
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Telemetry
  alias FermixCore.Timeouts

  # §6.2 caps. The hello deadline is a failure deadline: its VALUE is named in
  # `Timeouts` (the bridge verb waits on the same one, so the two ends of the
  # exchange cannot drift) and its firing is routed through `Timeouts.expired/3`
  # rather than logged ad hoc.
  @max_hello_bytes 262_144

  @mcp_refusal "session-scoped MCP servers are not supported yet; " <>
                 "configure MCP in Fermix's own config"

  # ACP `ToolKind` (priv/acp/schema.json `$defs/ToolKind`) is a display hint —
  # it tells a client which icon to draw. Fermix's policy classes are a
  # permission axis, so this map is an APPROXIMATION, deliberately coarse
  # (§15 open question 3): reads read, network fetches, everything that acts
  # executes. A client must never infer what a tool may do from it.
  @tool_kinds %{
    read_only: "read",
    network: "fetch",
    external_api: "fetch",
    read_write: "execute",
    exec: "execute",
    gui_control: "execute"
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The bridge ack line for a refusal, so the listener can turn a connection away
  in the bridge's own language before any Peer exists.
  """
  @spec refusal_line(String.t()) :: binary()
  def refusal_line(message) when is_binary(message) do
    ack_line(%{"status" => "error", "message" => message})
  end

  @impl true
  def init(opts) do
    hello_timeout_ms = Keyword.get(opts, :hello_timeout_ms, Timeouts.acp_bridge_hello())

    {:ok,
     %{
       socket: Keyword.fetch!(opts, :socket),
       registry: Keyword.get(opts, :registry, Acp.registry()),
       agent: Keyword.get(opts, :agent, Queue),
       agent_server: Keyword.get(opts, :agent_server, Queue),
       hello_timeout_ms: hello_timeout_ms,
       hello_timer: Process.send_after(self(), :hello_deadline, hello_timeout_ms),
       buffer: "",
       handshake: :pending,
       env: nil,
       sessions: %{}
     }}
  end

  @impl true
  def handle_info(:socket_handover, state), do: rearm(state)

  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    case drain(%{state | buffer: state.buffer <> bytes}) do
      {:cont, state} -> rearm(state)
      {:stop, state} -> {:stop, :normal, teardown(state)}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.info("ACP bridge disconnected; stopping #{map_size(state.sessions)} session(s)")
    {:stop, :normal, teardown(state)}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.warning("ACP peer socket error: #{inspect(reason)}")
    {:stop, :normal, teardown(state)}
  end

  def handle_info(:hello_deadline, %{handshake: :pending} = state) do
    _ = Timeouts.expired(:acp_bridge_hello, state.hello_timeout_ms, %{})

    state
    |> write(refusal_line("no bridge handshake within #{state.hello_timeout_ms}ms"))
    |> then(&{:stop, :normal, &1})
  end

  def handle_info(:hello_deadline, state), do: {:noreply, state}

  def handle_info({:acp_event, session_id, seq, payload}, state) do
    {:noreply, route_event(session_id, seq, payload, state)}
  end

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.socket)
    :ok
  end

  # --- Socket plumbing ---

  defp rearm(state) do
    case :inet.setopts(state.socket, [{:active, :once}]) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Logger.debug("ACP peer could not arm its socket: #{inspect(reason)}")
        {:stop, :normal, teardown(state)}
    end
  end

  # Splits complete lines out of the buffer, one at a time. Bounded by the buffer
  # itself: every pass either consumes a line or stops on the size cap.
  defp drain(state) do
    case :binary.match(state.buffer, "\n") do
      {index, 1} -> drain_line(index, state)
      :nomatch -> drain_partial(state)
    end
  end

  # The newline's offset IS the line's length, so a complete-but-oversize line is
  # refused on the same rule as one that never terminates — the cap is a property
  # of the line, not of how the bytes happened to arrive.
  defp drain_line(index, state) do
    if index > line_cap(state) do
      refuse_oversize(state)
    else
      <<line::binary-size(index), _newline::binary-size(1), rest::binary>> = state.buffer
      drain_next(line, %{state | buffer: rest})
    end
  end

  defp drain_next(line, state) do
    case handle_line(String.trim(line), state) do
      {:cont, state} -> drain(state)
      {:stop, state} -> {:stop, state}
    end
  end

  defp drain_partial(state) do
    if byte_size(state.buffer) > line_cap(state), do: refuse_oversize(state), else: {:cont, state}
  end

  defp line_cap(%{handshake: :pending}), do: @max_hello_bytes
  defp line_cap(_state), do: Wire.max_line_bytes()

  defp refuse_oversize(%{handshake: :pending} = state) do
    Logger.error("ACP bridge handshake line exceeded #{@max_hello_bytes} bytes; closing")
    {:stop, write(state, refusal_line("the bridge handshake line is too large"))}
  end

  defp refuse_oversize(state) do
    Logger.error("ACP peer closing: a protocol line exceeded #{Wire.max_line_bytes()} bytes")
    {:stop, state}
  end

  defp write(state, line) when is_binary(line) do
    case :gen_tcp.send(state.socket, line) do
      :ok -> state
      {:error, reason} -> log_write_failure(state, reason)
    end
  end

  defp log_write_failure(state, reason) do
    Logger.warning("ACP peer write failed: #{inspect(reason)}")
    state
  end

  # --- Bridge handshake (§6.2) ---

  defp handle_line("", state), do: {:cont, state}
  defp handle_line(line, %{handshake: :pending} = state), do: handle_hello(line, state)
  defp handle_line(line, state), do: {:cont, handle_frame(line, state)}

  defp handle_hello(line, state) do
    case Jason.decode(line) do
      {:ok, %{"fermix_bridge" => 1} = hello} ->
        accept_hello(hello, state)

      {:ok, %{"fermix_bridge" => version}} ->
        refuse_hello(
          state,
          "unsupported bridge version #{inspect(version)}; this daemon speaks fermix_bridge 1"
        )

      {:ok, _frame} ->
        refuse_hello(state, "the first line must be the fermix_bridge handshake")

      {:error, _reason} ->
        refuse_hello(state, "the fermix_bridge handshake line is not valid JSON")
    end
  end

  defp accept_hello(%{"env" => env} = hello, state) when is_map(env),
    do: complete_handshake(hello, env, state)

  defp accept_hello(hello, state) when not is_map_key(hello, "env"),
    do: complete_handshake(hello, %{}, state)

  defp accept_hello(_hello, state),
    do: refuse_hello(state, "the fermix_bridge handshake env must be an object")

  # The env is filtered HERE, once, before it is stored: everything outside the
  # allowlist is gone before any session can see it (§4).
  defp complete_handshake(hello, env, state) do
    session_env = SessionEnv.new(env)

    Logger.info(
      "ACP bridge connected (app_version=#{inspect(Map.get(hello, "app_version"))}); " <>
        "session env keys: #{inspect(SessionEnv.keys(session_env))}"
    )

    state = %{cancel_hello_timer(state) | handshake: :complete, env: session_env}
    {:cont, write(state, ack_line(%{"status" => "ok"}))}
  end

  defp refuse_hello(state, message) do
    Logger.error("ACP bridge handshake refused: #{message}")
    {:stop, write(cancel_hello_timer(state), refusal_line(message))}
  end

  defp cancel_hello_timer(%{hello_timer: timer} = state) when is_reference(timer) do
    _ = Process.cancel_timer(timer)
    %{state | hello_timer: nil}
  end

  defp cancel_hello_timer(state), do: state

  # The ack is NOT a JSON-RPC frame: it is the bridge's own control line, and it
  # is only ever written before the connection becomes a raw ACP pump (§6.2).
  defp ack_line(ack), do: Jason.encode!(%{"fermix_bridge_ack" => ack}) <> "\n"

  # --- ACP dispatch (§7) ---

  defp handle_frame(line, state) do
    {result, duration_us} = Telemetry.timed_us(fn -> Wire.decode_line(line) end)
    ChannelTelemetry.emit_parse(:acp, result, duration_us)
    dispatch(result, state)
  end

  defp dispatch({:ok, %{type: :request, id: id, method: method, params: params}}, state) do
    handle_request(method, id, params, state)
  end

  defp dispatch({:ok, %{type: :notification, method: method, params: params}}, state) do
    handle_notification(method, params, state)
  end

  defp dispatch({:ok, %{type: :response, id: id}}, state) do
    Logger.debug("ACP peer ignoring a response frame (id=#{inspect(id)}); it sends no requests")
    state
  end

  defp dispatch({:error, %Wire.Error{} = error}, state) do
    write(state, Wire.encode_error(nil, error))
  end

  defp handle_request("initialize", id, %{"protocolVersion" => version}, state)
       when is_integer(version) do
    write(state, Wire.encode_response(id, initialize_result(version)))
  end

  defp handle_request("initialize", id, _params, state) do
    write(state, Wire.encode_error(id, Wire.invalid_params("protocolVersion must be an integer")))
  end

  defp handle_request("session/new", id, params, state) do
    with {:ok, cwd} <- validate_cwd(params),
         :ok <- validate_mcp_servers(params) do
      open_session(id, cwd, params, state)
    else
      {:error, %Wire.Error{} = error} -> write(state, Wire.encode_error(id, error))
    end
  end

  defp handle_request("session/prompt", id, params, state) do
    with {:ok, session} <- fetch_idle_session(state, params),
         {:ok, content} <- fold_prompt(params) do
      start_prompt(session, id, content, state)
    else
      {:error, %Wire.Error{} = error} -> write(state, Wire.encode_error(id, error))
    end
  end

  # `authenticate`, every `session/*` management verb, `logout`, and anything
  # unknown answer identically: this agent advertises none of them, and the spec's
  # answer for an unadvertised method is -32601 (§7).
  defp handle_request(method, id, _params, state) do
    Logger.debug("ACP peer refusing unsupported method #{method}")
    write(state, Wire.encode_error(id, Wire.method_not_found("#{method} is not supported")))
  end

  defp handle_notification("session/cancel", %{"sessionId" => session_id}, state)
       when is_binary(session_id) do
    cancel_session(session_id, state)
  end

  # `CancelRequestNotification` in priv/acp/schema.json carries `{"requestId": …}`.
  defp handle_notification("$/cancel_request", %{"requestId" => request_id}, state)
       when is_binary(request_id) or is_number(request_id) do
    cancel_request(request_id, state)
  end

  defp handle_notification(method, _params, state) do
    Logger.debug("ACP peer ignoring notification #{method}")
    state
  end

  defp initialize_result(client_version) do
    %{
      "protocolVersion" => Wire.negotiate(client_version),
      "agentCapabilities" => %{"loadSession" => false, "promptCapabilities" => %{}},
      "authMethods" => [],
      "agentInfo" => %{"name" => "fermix", "version" => agent_version()}
    }
  end

  defp agent_version do
    case Application.spec(:fermix_core, :vsn) do
      nil -> "unknown"
      vsn -> List.to_string(vsn)
    end
  end

  # --- session/new ---

  defp validate_cwd(%{"cwd" => cwd}) when is_binary(cwd), do: absolute_cwd(cwd)

  defp validate_cwd(_params),
    do: {:error, Wire.invalid_params("cwd is required and must be an absolute path")}

  defp absolute_cwd(cwd) do
    case Path.type(cwd) do
      :absolute -> {:ok, cwd}
      _relative -> {:error, Wire.invalid_params("cwd must be an absolute path")}
    end
  end

  # An omitted `mcpServers` means the client attached none; a non-empty one is
  # the one deliberate gap in v1 conformance (§4) and is refused by name.
  defp validate_mcp_servers(%{"mcpServers" => []}), do: :ok

  defp validate_mcp_servers(%{"mcpServers" => servers}) when is_list(servers),
    do: {:error, Wire.invalid_params(@mcp_refusal)}

  defp validate_mcp_servers(%{"mcpServers" => _other}),
    do: {:error, Wire.invalid_params("mcpServers must be an array")}

  defp validate_mcp_servers(_params), do: :ok

  defp open_session(id, cwd, params, state) do
    session = Session.new(cwd, session_title(params))
    {:ok, _pid} = Registry.register(state.registry, session.id, nil)

    Logger.info(
      "ACP session #{session.id} opened (title=#{inspect(session.title)}, cwd=#{session.cwd})"
    )

    state
    |> put_session(session)
    |> write(Wire.encode_response(id, %{"sessionId" => session.id}))
  end

  defp session_title(params) do
    case get_in(params, ["_meta", "sessionTitle"]) do
      title when is_binary(title) -> title
      _absent -> nil
    end
  end

  # --- session/prompt ---

  defp fetch_idle_session(state, params) do
    with {:ok, session} <- fetch_session(state, params), do: require_idle(session)
  end

  defp fetch_session(state, params) do
    case Map.get(state.sessions, Map.get(params, "sessionId")) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, Wire.invalid_params("unknown sessionId; open one with session/new")}
    end
  end

  # The spec forbids a concurrent prompt without naming a code; this is our
  # server response, documented as such (§7).
  defp require_idle(%Session{turn: nil} = session), do: {:ok, session}

  defp require_idle(%Session{}),
    do: {:error, Wire.invalid_request("a prompt is already in flight for this session")}

  defp fold_prompt(params) do
    case Session.fold_prompt(Map.get(params, "prompt")) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, Wire.invalid_params(prompt_refusal(reason))}
    end
  end

  defp prompt_refusal({:unsupported_block, type}) do
    "#{type} content blocks are not supported; this agent advertises text and resource_link only"
  end

  defp prompt_refusal(:empty_prompt), do: "the prompt carries no text content"
  defp prompt_refusal(:malformed_prompt), do: "prompt must be a list of ACP content blocks"

  defp start_prompt(session, request_id, content, state) do
    {session, seq} = Session.start_turn(session, request_id)
    message = build_message(session, seq, content, state)
    state = put_session(state, session)

    {result, duration_us} = Telemetry.timed_us(fn -> ingest(message, state) end)
    ChannelTelemetry.emit_message(:acp, :inbound, 1, duration_us)

    handle_ingest(result, session, request_id, state)
  end

  defp handle_ingest(:ok, _session, _request_id, state), do: state

  # The turn will never run, so nothing else can answer this request: close it
  # here rather than leave the client waiting on its idle timer.
  defp handle_ingest({:error, reason}, session, request_id, state) do
    Logger.error("ACP prompt was not accepted for #{session.id}: #{inspect(reason)}")

    state
    |> put_session(Session.clear_turn(session))
    |> write(Wire.encode_error(request_id, Wire.internal_error("the prompt could not be queued")))
  end

  defp ingest(message, state) do
    Gateway.ingest([message],
      channel: Acp,
      agent: state.agent,
      agent_server: state.agent_server
    )
  end

  defp build_message(session, seq, content, state) do
    metadata =
      %{source: :acp, user_id: "acp", chat_type: "private"}
      |> Map.put(Acp.turn_opt(), seq)

    Message.new!(%{
      id: "acp-turn-" <> Integer.to_string(System.unique_integer([:positive, :monotonic])),
      content: content,
      sender: "acp-client",
      channel: Acp.channel(),
      chat_id: session.id,
      reply_target: session.id,
      request_cwd: session.cwd,
      session_env: SessionEnv.to_map(state.env),
      metadata: metadata,
      media_parts: []
    })
  end

  # --- Cancellation (§8.5) ---

  defp cancel_session(session_id, state) do
    case Map.get(state.sessions, session_id) do
      %Session{turn: turn} = session when is_map(turn) -> stop_turn(session, state)
      _idle_or_unknown -> log_idle_cancel(session_id, state)
    end
  end

  defp log_idle_cancel(session_id, state) do
    Logger.debug("ACP cancel for #{session_id} with no turn in flight; nothing to stop")
    state
  end

  # Stops the conversation and returns: the Queue answers with `{:cancelled}`
  # through the turn-result callback, and THAT writes the terminal response, so
  # there is exactly one place a prompt is answered from.
  #
  # A cancel that races an enqueue the Queue has not processed yet finds nothing
  # to stop; the turn then completes normally and answers `end_turn`. That is the
  # truth of what happened, so it is left alone rather than papered over.
  defp stop_turn(%Session{} = session, state) do
    Logger.info("ACP cancelling the turn in flight for #{session.id}")
    _ = Queue.stop_conversation(conversation_key(session.id), state.agent_server)
    state
  end

  # Only a `session/prompt` can be outstanding: every other request is answered
  # within the frame that carried it, so there is never a pending non-prompt id
  # to cancel.
  defp cancel_request(request_id, state) do
    case Enum.find(Map.values(state.sessions), &(Session.request_id(&1) == request_id)) do
      %Session{} = session -> cancel_prompt_request(session, request_id, state)
      nil -> log_unknown_cancel(request_id, state)
    end
  end

  defp cancel_prompt_request(session, request_id, state) do
    session
    |> stop_turn(state)
    |> put_session(Session.clear_turn(session))
    |> write(Wire.encode_error(request_id, Wire.request_cancelled()))
  end

  defp log_unknown_cancel(request_id, state) do
    Logger.debug("ACP $/cancel_request for #{inspect(request_id)}: nothing is pending")
    state
  end

  defp conversation_key(session_id) do
    ConversationKey.from(%{channel: Acp.channel(), chat_id: session_id})
  end

  # --- Turn events (§8.4) ---

  defp route_event(session_id, seq, payload, state) do
    case Map.get(state.sessions, session_id) do
      %Session{} = session -> apply_if_open(session, seq, payload, state)
      nil -> drop_late(session_id, seq, payload, state)
    end
  end

  defp apply_if_open(session, seq, payload, state) do
    if Session.turn_open?(session, seq) do
      apply_event(session, payload, state)
    else
      drop_late(session.id, seq, payload, state)
    end
  end

  defp drop_late(session_id, seq, payload, state) do
    Logger.debug(
      "ACP peer dropped a late #{elem(payload, 0)} for #{session_id} turn #{inspect(seq)}"
    )

    state
  end

  defp apply_event(session, {:stream, event}, state), do: apply_stream(session, event, state)
  defp apply_event(session, {:activity, event}, state), do: apply_activity(session, event, state)
  defp apply_event(session, {:reply, part}, state), do: apply_reply(session, part, state)

  defp apply_event(session, {:turn_result, outcome}, state),
    do: apply_turn_result(session, outcome, state)

  # Cumulative snapshots become suffix chunks; a new iteration restarts the
  # baseline; reasoning and session markers never reach the wire (v1, §8.4).
  defp apply_stream(session, {kind, cumulative}, state)
       when kind in [:text_delta, :text_done] and is_binary(cumulative) do
    {suffix, session} = Session.unsent_suffix(session, cumulative)
    state |> put_session(session) |> write_chunk(session.id, suffix)
  end

  defp apply_stream(session, {:iteration_started, _iteration}, state) do
    put_session(state, Session.reset_stream(session))
  end

  defp apply_stream(_session, _event, state), do: state

  defp apply_activity(session, {:tool_start, name}, state) when is_binary(name) do
    {tool_call_id, session} = Session.start_tool(session, name)

    state
    |> put_session(session)
    |> write(tool_call_frame(session.id, tool_call_id, name))
  end

  defp apply_activity(session, {:tool_finish, name, %{status: status}}, state)
       when is_binary(name) and status in [:ok, :error] do
    case Session.finish_tool(session, name) do
      {:ok, tool_call_id, session} ->
        state
        |> put_session(session)
        |> write(tool_update_frame(session.id, tool_call_id, status))

      :error ->
        Logger.debug("ACP peer saw #{name} finish with no matching tool_call; update dropped")
        state
    end
  end

  defp apply_activity(_session, _event, state), do: state

  # The FIRST text of a turn is the authoritative final reply: emit whatever the
  # stream has not already written. Anything after it is housekeeping (the
  # compaction notice, delivered post-commit) and is not part of the answer.
  defp apply_reply(session, {:text, text}, state) when is_binary(text) do
    if Session.final_seen?(session) do
      drop_post_final(session, state)
    else
      emit_final(session, text, state)
    end
  end

  defp apply_reply(session, {:media, media_part}, state) when is_map(media_part) do
    write_chunk(state, session.id, attachment_line(media_part))
  end

  defp apply_reply(session, part, state) do
    Logger.debug("ACP peer ignoring reply part #{inspect(elem(part, 0))} for #{session.id}")
    state
  end

  defp drop_post_final(session, state) do
    Logger.debug("ACP peer dropped a post-final delivery for #{session.id}")
    state
  end

  defp emit_final(session, text, state) do
    {suffix, session} = Session.unsent_suffix(session, text)

    state
    |> put_session(Session.mark_final_seen(session))
    |> write_chunk(session.id, suffix)
  end

  defp apply_turn_result(session, outcome, state) do
    request_id = Session.request_id(session)

    state
    |> put_session(Session.clear_turn(session))
    |> write(terminal_frame(request_id, outcome))
  end

  defp terminal_frame(request_id, {:completed}),
    do: Wire.encode_response(request_id, %{"stopReason" => "end_turn"})

  defp terminal_frame(request_id, {:cancelled}),
    do: Wire.encode_response(request_id, %{"stopReason" => "cancelled"})

  defp terminal_frame(request_id, {:failed, reason}),
    do: Wire.encode_error(request_id, failure_error(reason))

  # The raw reason goes to the log; the wire gets a bounded public rendering.
  # An auth-shaped failure is mapped to -32000 with a message starting
  # "Re-authenticate: " because Buzz dead-letters on exactly that word instead of
  # retrying a credential failure ten times (§2.2). Matching the inspected reason
  # is an APPROXIMATION: provider auth failures are not a typed family, so this
  # recognises how they read rather than what they are.
  defp failure_error(reason) do
    Logger.error("ACP turn failed: #{inspect(reason)}")

    if auth_failure?(reason) do
      Wire.auth_required(
        "Re-authenticate: the model provider rejected Fermix's credentials. " <>
          "Refresh them on the Fermix host (`fermix setup`), then retry."
      )
    else
      Wire.internal_error("the Fermix turn failed; the daemon log has the reason")
    end
  end

  @auth_markers ["401", "unauthorized", "invalid api key", "expired credentials"]

  defp auth_failure?(reason) do
    text = reason |> inspect() |> String.downcase()
    Enum.any?(@auth_markers, &String.contains?(text, &1))
  end

  # --- Frames ---

  defp write_chunk(state, _session_id, ""), do: state

  defp write_chunk(state, session_id, text) when is_binary(text) do
    write(
      state,
      session_update(session_id, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      })
    )
  end

  defp tool_call_frame(session_id, tool_call_id, name) do
    session_update(session_id, %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => tool_call_id,
      "title" => name,
      "kind" => tool_kind(name),
      "status" => "in_progress"
    })
  end

  defp tool_update_frame(session_id, tool_call_id, status) do
    session_update(session_id, %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => tool_call_id,
      "status" => tool_status(status)
    })
  end

  defp session_update(session_id, update) do
    Wire.encode_notification("session/update", %{"sessionId" => session_id, "update" => update})
  end

  defp tool_status(:ok), do: "completed"
  defp tool_status(:error), do: "failed"

  defp tool_kind(name) do
    case CapabilityRegistry.find(name) do
      {:ok, %{policy_class: policy_class}} -> Map.get(@tool_kinds, policy_class, "other")
      :error -> "other"
    end
  end

  defp attachment_line(media_part) do
    filename = Map.get(media_part, :filename) || Path.basename(Map.fetch!(media_part, :path))
    "[attachment: #{filename} — not transferable over this surface]"
  end

  # --- State ---

  defp put_session(state, %Session{} = session) do
    %{state | sessions: Map.put(state.sessions, session.id, session)}
  end

  # Bridge disconnect is a cancel for every turn still running (§6.2): the
  # client-owned session is gone, so nothing could receive their replies.
  # Registry entries deregister automatically when this process exits.
  defp teardown(state) do
    Enum.each(state.sessions, fn {_id, session} -> stop_open_turn(session, state) end)
    state
  end

  defp stop_open_turn(%Session{turn: turn} = session, state) when is_map(turn) do
    _ = stop_turn(session, state)
    :ok
  end

  defp stop_open_turn(%Session{}, _state), do: :ok
end
