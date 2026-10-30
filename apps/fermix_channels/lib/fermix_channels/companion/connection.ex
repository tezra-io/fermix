defmodule FermixChannels.Companion.Connection do
  @moduledoc """
  One client connection on `companion.sock`.

  The endpoint starts it and hands it the accepted socket; from then on this
  process owns the socket, so the fd closes the instant it exits, however it
  exits. It reads newline-delimited JSON through `FermixCore.Companion.Protocol`,
  enforces the mandatory hello handshake exactly as the Realtime socket does,
  and serves the chat vocabulary through the request path the phone shares
  (`Companion.Requests`).

  A `msg` or `command` runs in one supervised worker at a time, so this process
  stays free for `cancel`, history and search while a request is claimed and
  ingested; the worker is not linked, because a claimed request must settle
  whether or not its client stays. Everything the turn says afterwards arrives
  here from `Channels.Companion` through the registry this connection joins
  after its handshake.

  A protocol violation (a malformed or oversized line, an unknown event, an
  event before the handshake, a second hello) is answered with one `error` and
  the connection closes. A request that fails is answered with one `error` and
  the connection stays open.

  The version its hello declared is the connection's value in that registry,
  and it is never sent a server event a later version brought
  (`Protocol.server_event_version/1`): a version 2 client never sees
  `row_updated`, `media_path` or `media_missing`. A client event a later
  version brought (`Protocol.client_event_version/1`) is refused as unknown.
  Whoever asks whether a turn may end with no reply reads the versions
  attached there (M56 §6).

  ## Media (version 3, M66)

  A `media_fetch` is served only for a ref a row of the profile names, read
  with the query the phone's own `media_fetch` uses
  (`Timeline.media_descriptor/3`), and granted as a managed file through
  `Companion.MediaGrants` (`:media_grants`), which holds it for this process
  until a `media_release` for the ref or this process's exit. Nothing to grant
  is answered `media_missing`; a failure of the daemon's own is answered
  `request_failed` naming the ref, and the connection stays open.

  ## Proposals (version 4, M60 app surface §3.7)

  A mandate's proposals reach only a connection on version 4 that was placed
  as the owner's (`:independent`): `proposal` and `proposal_resolved`
  (`Protocol.owner_server_events/0`) are written to no other, as an event a
  later version brought is not (a watcher's follow-up card needs version 5,
  `Protocol.server_payload_version/2`), and the card of every proposal still waiting
  follows the `server_hello` in the step that joined the registry, read from
  `cue_proposals` (`Companion.Proposals.waiting/1`), so it survives a restart.
  A `proposal_answer` is served in the step that read it (one or two Repo
  calls; a confirmed call runs in a task of core's): `accepted` once the
  decision is recorded, then `proposal_resolved` when core announces the end,
  or `error: request_failed` with core's sentence. From a connection placed
  otherwise it is refused, and nothing runs. `:proposal_opts` are core's
  `Cues.Proposals` options (a test's repo and seams).

  ## Who is on the other end (SIDE-V1)

  When the socket is handed over, before any line is read, the connection
  places the process that connected (`FermixCore.SocketPeer`, the resolver the
  daemon control socket and the ACP socket use) and hands the answer with every
  `msg` and `command` it queues, for `Channels.Companion` to stamp on the turn as
  `metadata.caller`. A client started by the daemon's own shell command is the
  agent, not the Mac app, so its turns are unattended, as are a detached
  client's. A connection that cannot be placed is refused with one `error`
  (`unidentified_client`) and closed.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.MediaGrants
  alias FermixChannels.Companion.Output
  alias FermixChannels.Companion.Proposals
  alias FermixChannels.Companion.Requests
  alias FermixChannels.Companion.Turns
  alias FermixCore.Companion.Protocol
  alias FermixCore.Companion.Timeline
  alias FermixCore.SocketPeer

  @profile "main"
  @max_pending_requests 32
  @max_tracked_streams 8
  # One `history_page` is one line; the rows are cut to fit under the 64 KiB
  # line a client reads.
  @max_page_bytes 60 * 1_024
  @handover_timeout_ms 5_000
  @task_not_running_message "No task of that call is still running under that revision."

  # The closed vocabulary of `error.reason` this socket sends, besides
  # `unsupported_protocol_version`, `max_clients_reached` (the endpoint's),
  # `unidentified_client` (the handover's), the field and event errors that name
  # what they refused, and `request_failed`, which every other failure becomes.
  @named_reasons ~w(
    invalid_json invalid_event missing_type attachments_unsupported missing_protocol_version
    invalid_protocol_version line_too_large handshake_required unexpected_client_hello
    client_message_conflict unsupported_profile request_backlog_full
  )a

  @type state :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Every `error.reason` this socket can send."
  @spec error_reasons() :: [String.t()]
  def error_reasons do
    Enum.map(@named_reasons, &Atom.to_string/1) ++
      ~w(missing_field invalid_field unknown_event unsupported_protocol_version
         max_clients_reached unidentified_client request_failed)
  end

  @doc """
  Recover one stored companion request at boot. Nobody is waiting for its
  `accepted`; its turn speaks to every connection that has joined by then.
  """
  @spec recover_request(map(), map(), keyword()) :: :ok | {:error, term()}
  def recover_request(row, %{transport: :companion}, opts) when is_map(row) and is_list(opts) do
    sink = &sink(Companion.registry(), &1, &2)

    opts =
      [agent: Turns, settlement_owner: Turns]
      |> Keyword.merge(opts)
      |> Keyword.put(:event_sink, sink)

    Requests.recover(row, transport(nil), opts)
  end

  @impl true
  def init(opts) do
    state = %{
      socket: Keyword.fetch!(opts, :socket),
      buffer: "",
      version: nil,
      streams: %{},
      pending: [],
      worker: nil,
      registry: Keyword.get(opts, :registry, Companion.registry()),
      approvals: Keyword.get(opts, :approvals, Approvals.server()),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      request_opts: Keyword.get(opts, :request_opts, []),
      # The grants server, and the module that speaks to it (a test's stand-in).
      media_grants: Keyword.get(opts, :media_grants, MediaGrants),
      media_grants_module: Keyword.get(opts, :media_grants_module, MediaGrants),
      proposal_opts: Keyword.get(opts, :proposal_opts, []),
      # Placed once at handover, before any line is read (moduledoc); the
      # daemon's process and platform are seams a test stands in for.
      daemon_os_pid: Keyword.get(opts, :daemon_os_pid, String.to_integer(System.pid())),
      os: Keyword.get(opts, :os, :os.type()),
      caller: nil
    }

    {:ok, state, @handover_timeout_ms}
  end

  @impl true
  def handle_info(:socket_handover, state) do
    case SocketPeer.classify(state.socket, state.daemon_os_pid, state.os) do
      {:ok, caller} -> arm(%{state | caller: caller})
      # Nobody is left to read a refusal, as when the socket reads closed.
      {:error, :peer_closed} -> {:stop, :normal, state}
      {:error, reason} -> refuse_unplaced(reason, state)
    end
  end

  # The endpoint died between starting this process and handing it the socket.
  def handle_info(:timeout, %{version: nil, buffer: ""} = state),
    do: {:stop, {:shutdown, :handover_timeout}, state}

  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    case drain_lines(%{state | buffer: state.buffer <> bytes}) do
      {:cont, state} -> rearm(state)
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.debug("companion connection read error: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:companion_event, event}, state),
    do: write_event(event, forget_stream(event, state))

  def handle_info({:companion_stream, turn_id, update}, state),
    do: write_stream(turn_id, update, state)

  def handle_info({:companion_request_failed, client_msg_id, reason}, state),
    do: write_request_error(reason, client_msg_id, state)

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worker: {ref, client_msg_id}} = state) do
    state = %{state | worker: nil}

    with {:noreply, state} <- worker_exit(reason, client_msg_id, state) do
      start_next_request(state)
    end
  end

  def handle_info(message, state) do
    Logger.debug("companion connection ignored #{inspect(message)}")
    {:noreply, state}
  end

  defp arm(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:shutdown, {:socket_arm_failed, reason}}, state}
    end
  end

  defp refuse_unplaced(reason, state) do
    Logger.warning(
      "companion connection refusing a client the daemon could not identify: #{inspect(reason)}"
    )

    _ = send_event("error", error_payload({:unidentified_client, reason}, nil), state)
    {:stop, :normal, state}
  end

  defp rearm(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  defp drain_lines(%{buffer: buffer} = state) do
    case :binary.split(buffer, "\n") do
      [line, rest] -> process_line(line, %{state | buffer: rest})
      [_partial] -> partial_line(state)
    end
  end

  defp partial_line(state) do
    if byte_size(state.buffer) > Protocol.max_line_bytes(),
      do: refuse(:line_too_large, state),
      else: {:cont, state}
  end

  defp process_line(line, state) do
    cond do
      byte_size(line) > Protocol.max_line_bytes() -> refuse(:line_too_large, state)
      String.trim(line) == "" -> drain_lines(state)
      true -> line |> String.trim() |> handle_line(state) |> continue_draining()
    end
  end

  defp continue_draining({:cont, state}), do: drain_lines(state)
  defp continue_draining({:stop, state}), do: {:stop, state}

  defp handle_line(line, state) do
    case Protocol.decode_client_event(line) do
      {:ok, event} -> dispatch(event, state)
      {:error, reason} -> refuse(reason, state)
    end
  end

  defp dispatch(%{type: "client_hello", payload: payload}, state), do: hello(payload, state)
  defp dispatch(_event, %{version: nil} = state), do: refuse(:handshake_required, state)

  # An event a later version brought is not in the vocabulary of a connection
  # whose hello declared an older one.
  defp dispatch(%{type: type} = event, state) do
    if Protocol.client_event_version(type) <= state.version,
      do: serve(event, state),
      else: refuse({:unknown_event, type}, state)
  end

  defp serve(%{type: type} = event, state) when type in ["msg", "command"],
    do: queue_request(event, state)

  defp serve(%{type: "cancel", payload: payload}, state),
    do: answer(Requests.cancel(payload, request_opts(state)), state)

  defp serve(%{type: "history_pull", payload: payload}, state),
    do: answer(Requests.history(payload, transport(self()), read_opts(state)), state)

  defp serve(%{type: "history_search", payload: payload}, state),
    do: answer(Requests.search(payload, transport(self()), read_opts(state)), state)

  defp serve(%{type: "read_state", payload: payload}, state),
    do: answer(Requests.read_state(payload, request_opts(state)), state)

  defp serve(%{type: "media_fetch", payload: payload}, state), do: media_fetch(payload, state)
  defp serve(%{type: "media_release", payload: payload}, state), do: media_release(payload, state)

  defp serve(%{type: "proposal_answer", payload: payload}, state),
    do: proposal_answer(payload, state)

  # A repeat hello is a protocol violation: the handshake is one transition.
  defp hello(_payload, %{version: version} = state) when is_integer(version),
    do: refuse(:unexpected_client_hello, state)

  defp hello(%{"protocol_version" => version}, state) do
    case Protocol.negotiate(version) do
      :ok -> join(version, state)
      {:error, direction} -> refuse_version(direction, version, state)
    end
  end

  defp join(version, state) do
    {min, max} = Protocol.supported_version_range()

    with {:ok, _owner} <- Registry.register(state.registry, @profile, version),
         :ok <- send_event("server_hello", %{"min_version" => min, "max_version" => max}, state),
         :ok <- send_pending_approvals(state),
         state = %{state | version: version},
         :ok <- send_waiting_proposals(state) do
      {:cont, state}
    else
      _failed -> {:stop, state}
    end
  end

  # Every proposal still waiting follows the server_hello, oldest first, for
  # the owner's connection on version 4 alone (moduledoc); one that arrives
  # meanwhile may come twice, and the client keys cards by `proposal_id`.
  defp send_waiting_proposals(state) do
    state.proposal_opts
    |> Proposals.waiting()
    |> Enum.filter(fn %{"t" => type} = event -> owner_reads?(type, event, state) end)
    |> write_all(state)
  end

  defp write_all(events, state) do
    Enum.reduce_while(events, :ok, fn %{"t" => type} = event, :ok ->
      case send_event(type, Map.delete(event, "t"), state) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A proposal event is written to a connection on its version (a follow-up's
  # card, on version 5), placed as the owner's; every other event only needs
  # the version.
  defp owner_reads?(type, event, state) do
    Protocol.server_payload_version(type, event) <= state.version and
      (type not in Protocol.owner_server_events() or state.caller == :independent)
  end

  # An approval still waiting for the owner is written right after the
  # server_hello, in the step that joined the registry, so a client that was
  # not connected when it went out shows it, and its resolution can only
  # arrive after it. Only a card raised here: a phone's resolves only there.
  defp send_pending_approvals(state) do
    state.approvals
    |> Approvals.pending(@profile, :companion)
    |> Enum.reduce_while(:ok, fn approval, :ok ->
      case write_pending_approval(approval, state) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A card this wire has no shape for is a daemon bug, reported and skipped;
  # a socket that cannot be written ends the connection.
  defp write_pending_approval(%{"t" => type} = approval, state) do
    case Protocol.encode_server_event(type, Map.delete(approval, "t")) do
      {:ok, line} ->
        :gen_tcp.send(state.socket, line)

      {:error, reason} ->
        Logger.error("companion connection dropped a waiting approval: #{inspect(reason)}")
        :ok
    end
  end

  defp refuse_version(direction, client_version, state) do
    {min, max} = Protocol.supported_version_range()

    payload = %{
      "reason" => "unsupported_protocol_version",
      "direction" => Atom.to_string(direction),
      "client_version" => client_version,
      "min_version" => min,
      "max_version" => max
    }

    _ = send_event("error", payload, state)
    {:stop, state}
  end

  defp answer(:ok, state), do: {:cont, state}

  defp answer({:error, reason}, state) do
    case send_event("error", error_payload(reason, nil), state) do
      :ok -> {:cont, state}
      {:error, _reason} -> {:stop, state}
    end
  end

  # The grant is answered in the step that made it, as a page is (moduledoc).
  defp media_fetch(%{"profile_id" => @profile, "ref" => ref}, state) do
    {type, payload} = ref |> grant_media(state) |> media_answer(ref)

    case send_event(type, payload, state) do
      :ok -> {:cont, state}
      {:error, _reason} -> {:stop, state}
    end
  end

  defp media_fetch(_payload, state), do: answer({:error, :unsupported_profile}, state)

  # Never answered: releasing a ref this connection does not hold changes
  # nothing.
  defp media_release(%{"profile_id" => @profile, "ref" => ref}, state) do
    :ok = state.media_grants_module.release(state.media_grants, ref, self())
    {:cont, state}
  end

  defp media_release(_payload, state), do: answer({:error, :unsupported_profile}, state)

  # Answered in the step that read it (moduledoc): `accepted` once core
  # recorded the decision, or core's sentence as `request_failed`.
  defp proposal_answer(%{"profile_id" => @profile, "client_msg_id" => id} = payload, state) do
    {type, reply} =
      case Proposals.answer(payload, state.caller, state.proposal_opts) do
        {:ok, _record} ->
          {"accepted", %{"client_msg_id" => id, "duplicate" => false}}

        {:error, sentence} ->
          {"error", %{"reason" => "request_failed", "message" => sentence, "client_msg_id" => id}}
      end

    case send_event(type, reply, state) do
      :ok -> {:cont, state}
      {:error, _reason} -> {:stop, state}
    end
  end

  defp proposal_answer(%{"client_msg_id" => id}, state) do
    case send_event("error", error_payload(:unsupported_profile, id), state) do
      :ok -> {:cont, state}
      {:error, _reason} -> {:stop, state}
    end
  end

  defp grant_media(ref, state) do
    with {:ok, descriptor} <- media_descriptor(ref, state),
         {:ok, media} <- Timeline.normalize_media_descriptor(descriptor, ref),
         grant = Map.take(media, [:ref, :kind, :mime, :size_bytes]),
         {:ok, path} <- state.media_grants_module.grant(state.media_grants, grant, self()) do
      {:ok, path, media}
    end
  end

  defp media_descriptor(ref, state) do
    store = Keyword.get(state.request_opts, :store, Timeline)
    store.media_descriptor(@profile, ref, Keyword.get(state.request_opts, :store_opts, []))
  end

  defp media_answer({:ok, path, media}, ref) do
    {"media_path",
     %{
       "ref" => ref,
       "path" => path,
       "kind" => media.kind,
       "mime" => media.mime,
       "size_bytes" => media.size_bytes,
       "sha256" => ref
     }}
  end

  # No row names the ref, or the grant found nothing to copy.
  defp media_answer({:error, reason}, ref) when reason in [:not_found, :media_missing],
    do: {"media_missing", %{"ref" => ref}}

  defp media_answer({:error, reason}, ref) do
    Logger.warning("companion connection could not grant media #{ref}: #{inspect(reason)}")

    {"error",
     %{"reason" => "request_failed", "message" => Output.error_message(reason), "ref" => ref}}
  end

  defp queue_request(_event, %{pending: pending} = state)
       when length(pending) >= @max_pending_requests,
       do: answer({:error, :request_backlog_full}, state)

  # The caller rides with the request, outside the client's payload, for
  # `Channels.Companion` to stamp on the turn (moduledoc).
  defp queue_request(event, state) do
    event = Map.put(event, :caller, state.caller)

    case start_next_request(%{state | pending: state.pending ++ [event]}) do
      {:noreply, state} -> {:cont, state}
      {:stop, _reason, state} -> {:stop, state}
    end
  end

  defp start_next_request(%{worker: {_ref, _id}} = state), do: {:noreply, state}
  defp start_next_request(%{pending: []} = state), do: {:noreply, state}

  defp start_next_request(%{pending: [event | rest]} = state) do
    client_msg_id = event.payload["client_msg_id"]

    case Task.Supervisor.start_child(state.task_supervisor, request_job(event, state)) do
      {:ok, pid} ->
        {:noreply, %{state | pending: rest, worker: {Process.monitor(pid), client_msg_id}}}

      {:error, reason} ->
        {:stop, {:shutdown, {:request_worker_unavailable, reason}}, state}
    end
  end

  defp request_job(event, state) do
    connection = self()
    transport = transport(connection)
    opts = request_opts(state)
    client_msg_id = event.payload["client_msg_id"]

    fn ->
      case Requests.request(event, transport, opts) do
        :ok -> :ok
        {:error, reason} -> send(connection, {:companion_request_failed, client_msg_id, reason})
      end
    end
  end

  defp worker_exit(:normal, _client_msg_id, state), do: {:noreply, state}

  defp worker_exit(reason, client_msg_id, state),
    do: write_request_error({:request_failed, reason}, client_msg_id, state)

  defp write_request_error(reason, client_msg_id, state) do
    case send_event("error", error_payload(reason, client_msg_id), state) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  defp write_event(%{"t" => type} = event, state) do
    case Protocol.encode_server_event(type, Map.delete(event, "t")) do
      {:ok, line} -> write_in_version(type, event, line, state)
      {:error, reason} -> drop_event(type, reason, state)
    end
  end

  # An event a later version brought is not this client's to read, nor a
  # proposal event a connection not placed as the owner's: it is not sent, and
  # is no error.
  defp write_in_version(type, event, line, state) do
    if owner_reads?(type, event, state),
      do: write_line(line, state),
      else: {:noreply, state}
  end

  defp write_line(line, state) do
    case :gen_tcp.send(state.socket, line) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  # An event this wire has no shape for is a daemon bug, reported where the
  # daemon's operator reads, never forwarded half-formed to the client.
  defp drop_event(type, reason, state) do
    Logger.error("companion connection dropped a #{type} event: #{inspect(reason)}")
    {:noreply, state}
  end

  defp write_stream(turn_id, :reset, state),
    do: {:noreply, %{state | streams: track(state.streams, turn_id, "")}}

  defp write_stream(turn_id, {:snapshot, text}, state) do
    sent = Map.get(state.streams, turn_id, "")
    state = %{state | streams: track(state.streams, turn_id, text)}

    case unsent_suffix(sent, text) do
      "" -> {:noreply, state}
      suffix -> write_event(%{"t" => "text_delta", "turn_id" => turn_id, "text" => suffix}, state)
    end
  end

  # A snapshot that does not extend what was written restarted its text, so it
  # is sent whole.
  defp unsent_suffix(sent, text) do
    if String.starts_with?(text, sent),
      do: binary_part(text, byte_size(sent), byte_size(text) - byte_size(sent)),
      else: text
  end

  # Turns run one at a time per conversation, so only a turn whose terminal
  # event never arrived (its queue died) can linger; the bound drops those.
  defp track(streams, turn_id, text) do
    streams =
      if Map.has_key?(streams, turn_id) or map_size(streams) < @max_tracked_streams,
        do: streams,
        else: %{}

    Map.put(streams, turn_id, text)
  end

  defp forget_stream(%{"t" => type, "turn_id" => turn_id}, state)
       when type in ["text_done", "turn_error", "turn_done"],
       do: %{state | streams: Map.delete(state.streams, turn_id)}

  defp forget_stream(_event, state), do: state

  defp refuse(reason, state) do
    _ = send_event("error", error_payload(reason, nil), state)
    {:stop, state}
  end

  defp send_event(type, payload, state) do
    with {:ok, line} <- Protocol.encode_server_event(type, payload) do
      :gen_tcp.send(state.socket, line)
    end
  end

  defp error_payload(reason, client_msg_id) do
    reason
    |> error_fields()
    |> maybe_put("client_msg_id", client_msg_id)
  end

  defp error_fields({field_error, field}) when field_error in [:missing_field, :invalid_field],
    do: %{"reason" => Atom.to_string(field_error), "field" => field}

  defp error_fields({:unknown_event, type}), do: %{"reason" => "unknown_event", "event" => type}

  defp error_fields({:unidentified_client, cause}),
    do: %{
      "reason" => "unidentified_client",
      "message" =>
        "the daemon could not identify the process on this connection: " <>
          Output.error_message(cause)
    }

  defp error_fields(reason) when reason in @named_reasons,
    do: %{"reason" => Atom.to_string(reason)}

  # A cancel by `task_ref` that names no GPT-Live task still running under
  # exactly those ids (M56 §4.6): its own sentence, the connection kept.
  defp error_fields(:task_not_running),
    do: %{"reason" => "request_failed", "message" => @task_not_running_message}

  # A failure reason can carry an exception and its stacktrace: the message is
  # bounded so the error that reports it can always be written.
  defp error_fields({:request_failed, cause}),
    do: %{"reason" => "request_failed", "message" => Output.error_message(cause)}

  defp error_fields(reason),
    do: %{"reason" => "request_failed", "message" => Output.error_message(reason)}

  @doc """
  What this socket hands the shared request path (`t:Companion.Requests.transport/0`),
  with `reply_to` the connection whose client asked: its own pid, or `nil` at
  boot recovery, when nobody is waiting.
  """
  @spec transport(pid() | nil) :: Requests.transport()
  def transport(reply_to) when is_pid(reply_to) or is_nil(reply_to) do
    %{
      name: :companion,
      channel: Companion,
      claimant: [],
      ingress_context: %{transport: :companion},
      reply_to: reply_to,
      report_failure: request_failure_reporter(reply_to),
      attempt_key: :companion_attempt,
      max_page_bytes: @max_page_bytes,
      after_user_append: &announce_user_row/4,
      after_settle: nil
    }
  end

  # A request that fails after its worker returned is written as a failed
  # worker's is (`{:companion_request_failed, ...}`), by the connection that
  # took it.
  defp request_failure_reporter(nil), do: fn _client_msg_id, _cause -> :ok end

  defp request_failure_reporter(connection) do
    fn client_msg_id, cause ->
      send(connection, {:companion_request_failed, client_msg_id, {:request_failed, cause}})
      :ok
    end
  end

  # A user's row is announced to every client watching the profile as it is
  # written, this sender's own connection and the phones included, carrying its
  # `client_msg_id`, each wire in its own shape.
  defp announce_user_row(profile, row, _text, opts),
    do: Keyword.fetch!(opts, :event_sink).({:profile, profile}, Output.row(profile, row))

  defp request_opts(state) do
    registry = state.registry
    Keyword.put(state.request_opts, :event_sink, &sink(registry, &1, &2))
  end

  # A page or a search answer is written to the socket in the step that read
  # it, the way `server_hello` is, never through this process's mailbox: a live
  # event for a row written after the read can then only reach the socket after
  # the page, so every row is in the page or announced after it.
  defp read_opts(state) do
    Keyword.put(state.request_opts, :event_sink, fn _reply_to, %{"t" => type} = event ->
      send_event(type, Map.delete(event, "t"), state)
    end)
  end

  defp sink(_registry, pid, event) when is_pid(pid) do
    send(pid, {:companion_event, event})
    :ok
  end

  defp sink(registry, {:profile, profile_id}, event),
    do: Fanout.announce(profile_id, event, companion_registry: registry)

  defp sink(_registry, nil, _event), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
