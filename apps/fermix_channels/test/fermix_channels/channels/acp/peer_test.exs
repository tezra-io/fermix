defmodule FermixChannels.Channels.Acp.PeerTest do
  @moduledoc """
  The ACP vertical slice (M29 Stage 3) driven by a fake client over a real
  socket: bridge handshake, the §7 wire table, streamed chunks that reconcile
  with the final reply, tool cards, cancel + the wire fence, and error mapping.

  The turn stack below the gateway is the REAL `Gateway.Queue` with a scripted
  runner, so `stop_conversation/2`, the exactly-once `turn_result_fn`, and the
  `:raw` stream threading are exercised as they ship — only the provider call is
  scripted.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixChannels.Channels.Acp
  alias FermixChannels.Channels.Acp.Wire
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Queue
  alias FermixCore.Acp.Identity
  alias FermixCore.Acp.IdentityStore
  alias FermixTestSupport.SafeRm

  @cwd "/tmp/fermix-acp-session"

  # Published NIP-19 vectors (nostr/key_test.exs derives them) — test vectors,
  # never live keys.
  @nsec "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
  @public_hex "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
  @npub "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
  @other_nsec "nsec1n5kjpk2ulwe25uj4thrr8stmy0xe9hk7f0suw0sdeff34yfv2xkq2etz66"

  # Stands in for `MainAgent.checkout_turn_state/2`; the turn state only has to
  # carry the pid the scripted runner reports to.
  defmodule StubAgent do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:checkout_turn_state, _msg}, _from, opts) do
      {:reply, {:ok, %{test_pid: opts.test_pid}, :hit}, opts}
    end
  end

  # Announces its turn to the test, then replays whatever the test scripts:
  # stream events, activity events, mid-turn deliveries, and a terminal result.
  defmodule ScriptedRunner do
    def run(msg, turn_state, deliver), do: run(msg, turn_state, deliver, nil, nil)
    def run(msg, turn_state, deliver, stream), do: run(msg, turn_state, deliver, stream, nil)

    def run(msg, turn_state, deliver, stream, activity) do
      send(turn_state.test_pid, {:turn_started, msg, self()})
      script(deliver, stream, activity)
    end

    defp script(deliver, stream, activity) do
      receive do
        {:stream, event} ->
          stream.(event)
          script(deliver, stream, activity)

        {:activity, event} ->
          activity.(event)
          script(deliver, stream, activity)

        {:deliver, part} ->
          deliver.(part)
          script(deliver, stream, activity)

        {:finish, response} ->
          {:ok, response, 0}

        {:fail, reason} ->
          {:error, reason}

        :crash ->
          raise "scripted turn crash"
      after
        20_000 -> {:ok, "scripted runner timed out", 0}
      end
    end

    def commit(_msg, _turn_state, _response, _context_tokens), do: :ok
    def error_reply(_reason), do: "error reply"
  end

  # A short socket path on purpose: a Unix socket address is capped around 104
  # bytes, which a nested tmp directory blows straight through.
  setup do
    socket_path =
      Path.join(System.tmp_dir!(), "fermix-acp-#{System.unique_integer([:positive])}.sock")

    # A scratch FERMIX_HOME for every test in this module: a hello now writes a
    # durable identity record, and the host's own ~/.fermix must never gain one
    # because a test connected.
    previous_home = System.get_env("FERMIX_HOME")
    home = SafeRm.make_tmp_dir!("acp-peer-home")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      SafeRm.rm(socket_path)
      restore_home(previous_home)
      SafeRm.rm_rf!(home)
    end)

    task_supervisor = start_supervised!({Task.Supervisor, []})
    agent = start_supervised!({StubAgent, test_pid: self()}, id: :stub_agent)
    queue = :"acp_queue_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Queue,
       name: queue,
       main_agent: agent,
       turn_runner: ScriptedRunner,
       task_supervisor: task_supervisor},
      id: :acp_queue
    )

    start_supervised!(
      {Acp.Supervisor,
       socket_path: socket_path,
       peer_opts: [agent: Queue, agent_server: queue, hello_timeout_ms: 200]},
      id: :acp_supervisor
    )

    {:ok, socket_path: socket_path, queue: queue, identity_dir: IdentityStore.dir()}
  end

  describe "bridge handshake (§6.2)" do
    test "acks a well-formed hello and then speaks ACP", ctx do
      client = connect(ctx)

      assert :ok =
               send_json(client, %{"fermix_bridge" => 1, "app_version" => "0.0.0", "env" => %{}})

      assert %{"fermix_bridge_ack" => %{"status" => "ok"}} = recv_frame(client)

      assert %{"result" => %{"protocolVersion" => 1}} =
               request(client, 1, "initialize", %{"protocolVersion" => 1})
    end

    test "refuses a hello whose bridge version is not 1, naming both versions", ctx do
      client = connect(ctx)

      send_json(client, %{"fermix_bridge" => 2, "app_version" => "0.0.0", "env" => %{}})

      assert %{"fermix_bridge_ack" => %{"status" => "error", "message" => message}} =
               recv_frame(client)

      assert message =~ "2"
      assert message =~ "1"
      assert closed?(client)
    end

    test "refuses an ACP frame sent before the hello", ctx do
      client = connect(ctx)

      send_json(client, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{}
      })

      assert %{"fermix_bridge_ack" => %{"status" => "error", "message" => message}} =
               recv_frame(client)

      assert message =~ "handshake"
      assert closed?(client)
    end

    # Exactly one byte over the 256 KiB hello cap and no newline: the Peer
    # consumes every byte sent before it trips, so nothing is left unread and the
    # refusal it writes is deterministically readable.
    test "refuses an oversize hello", ctx do
      client = connect(ctx)

      :ok = :gen_tcp.send(client, String.duplicate("a", 262_145))

      assert %{"fermix_bridge_ack" => %{"status" => "error", "message" => message}} =
               recv_frame(client)

      assert message =~ "too large"
      assert closed?(client)
    end

    test "refuses a hello that never arrives", ctx do
      client = connect(ctx)

      assert %{"fermix_bridge_ack" => %{"status" => "error", "message" => message}} =
               recv_frame(client, 3_000)

      assert message =~ "handshake"
      assert closed?(client)
    end
  end

  describe "initialize (§7)" do
    test "answers version 1 whatever the client announced, with honest capabilities", ctx do
      client = handshake(connect(ctx))

      for announced <- [0, 1, 2, 99] do
        assert %{"result" => result} =
                 request(client, 100 + announced, "initialize", %{"protocolVersion" => announced})

        assert result["protocolVersion"] == 1

        assert result["agentCapabilities"] == %{
                 "loadSession" => false,
                 "promptCapabilities" => %{}
               }

        assert result["authMethods"] == []
        assert result["agentInfo"]["name"] == "fermix"
        assert is_binary(result["agentInfo"]["version"])
      end
    end

    test "refuses a non-integer protocolVersion", ctx do
      client = handshake(connect(ctx))

      assert %{"error" => %{"code" => -32_602}} =
               request(client, 1, "initialize", %{"protocolVersion" => "1"})

      assert %{"error" => %{"code" => -32_602}} = request(client, 2, "initialize", %{})
    end
  end

  describe "session/new (§7)" do
    test "mints a unique id per session and records the cwd", ctx do
      client = initialized(ctx)

      first = new_session(client, 2)
      second = new_session(client, 3)

      assert first != second
      assert <<"acp-", _hex::binary-size(32)>> = first
    end

    test "a session belongs to its own connection and no other", ctx do
      owner = initialized(ctx)
      stranger = initialized(ctx)
      session_id = new_session(owner, 2)

      assert %{"error" => %{"code" => -32_602, "message" => message}} =
               request(stranger, 3, "session/prompt", %{
                 "sessionId" => session_id,
                 "prompt" => [%{"type" => "text", "text" => "steal the session"}]
               })

      assert message =~ "session"
      refute_receive {:turn_started, _msg, _runner}, 200
    end

    test "refuses a relative cwd", ctx do
      client = initialized(ctx)

      assert %{"error" => %{"code" => -32_602, "message" => message}} =
               request(client, 2, "session/new", %{"cwd" => "relative/dir", "mcpServers" => []})

      assert message =~ "absolute"
    end

    test "refuses session-scoped MCP servers with the named message", ctx do
      client = initialized(ctx)

      assert %{"error" => %{"code" => -32_602, "message" => message}} =
               request(client, 2, "session/new", %{
                 "cwd" => @cwd,
                 "mcpServers" => [%{"name" => "fs", "command" => "mcp-fs", "args" => []}]
               })

      assert message ==
               "session-scoped MCP servers are not supported yet; " <>
                 "configure MCP in Fermix's own config"
    end
  end

  describe "unsupported methods (§7)" do
    test "authenticate, the session management verbs, and unknown methods answer -32601", ctx do
      client = initialized(ctx)

      methods = ~w(
        authenticate session/load session/list session/resume session/close session/delete
        session/set_mode session/set_config_option logout session/telepathy
      )

      for {method, index} <- Enum.with_index(methods, 10) do
        assert %{"error" => %{"code" => -32_601}} = request(client, index, method, %{}),
               "#{method} must answer -32601"
      end
    end

    test "an unknown notification is ignored", ctx do
      client = initialized(ctx)

      notify(client, "session/telepathy", %{"sessionId" => "nope"})

      # The connection is still healthy and answers the next request.
      assert %{"result" => _result} = request(client, 20, "initialize", %{"protocolVersion" => 1})
    end

    test "a malformed frame is answered with a parse error", ctx do
      client = handshake(connect(ctx))

      :gen_tcp.send(client, "{not json}\n")

      assert %{"error" => %{"code" => -32_700}, "id" => nil} = recv_frame(client)
    end
  end

  describe "a full prompt turn (§8)" do
    test "folds the prompt, streams suffix chunks, and ends the turn", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)

      prompt(client, 3, session_id, [
        %{"type" => "text", "text" => "/sandbox grant /tmp/x"},
        %{"type" => "text", "text" => "summarise the deploy log"},
        %{"type" => "resource_link", "uri" => "file:///tmp/deploy.log", "name" => "deploy.log"}
      ])

      assert_receive {:turn_started, msg, runner}, 5_000

      # `commands?: false` — the slash text is model input, verbatim, and the
      # resource link folded to its bracketed reference (§8.2).
      assert msg.content ==
               "/sandbox grant /tmp/x\n\nsummarise the deploy log\n\n" <>
                 "[resource: file:///tmp/deploy.log (deploy.log)]"

      assert msg.channel == "acp"
      assert msg.chat_id == session_id
      assert msg.request_cwd == @cwd

      stream(runner, {:session_started, "sess-1"})
      stream(runner, {:iteration_started, 1})
      stream(runner, {:text_delta, "The deploy"})
      stream(runner, {:reasoning_delta, "hmm"})
      stream(runner, {:text_delta, "The deploy failed"})
      stream(runner, {:text_done, "The deploy failed"})
      finish(runner, "The deploy failed at step 3.")

      {frames, response} = recv_response(client, 3)

      assert response["result"] == %{"stopReason" => "end_turn"}
      assert Enum.join(chunk_texts(frames)) == "The deploy failed at step 3."

      assert updates(frames) == [
               "agent_message_chunk",
               "agent_message_chunk",
               "agent_message_chunk"
             ]
    end

    test "an unstreamed turn still delivers the whole reply as one chunk", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "hi"}])

      assert_receive {:turn_started, _msg, runner}, 5_000
      finish(runner, "the whole answer")

      {frames, response} = recv_response(client, 3)

      assert response["result"] == %{"stopReason" => "end_turn"}
      assert chunk_texts(frames) == ["the whole answer"]
    end

    test "a post-final delivery (the compaction notice) never reaches the wire", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "hi"}])

      assert_receive {:turn_started, _msg, runner}, 5_000
      send(runner, {:deliver, {:text, "the authoritative answer"}})
      send(runner, {:deliver, {:text, "🗜️ Trimmed older conversation history"}})
      finish(runner, "the authoritative answer")

      {frames, response} = recv_response(client, 3)

      assert response["result"] == %{"stopReason" => "end_turn"}
      assert chunk_texts(frames) == ["the authoritative answer"]
    end

    test "an attachment renders as one text chunk naming the file", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "draw me a chart"}])

      assert_receive {:turn_started, _msg, runner}, 5_000
      send(runner, {:deliver, {:media, %{kind: :image, path: "/tmp/chart.png"}}})
      finish(runner, "here it is")

      {frames, _response} = recv_response(client, 3)

      assert chunk_texts(frames) == [
               "[attachment: chart.png — not transferable over this surface]",
               "here it is"
             ]
    end

    test "refuses a second prompt while one is in flight", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "first"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      prompt(client, 4, session_id, [%{"type" => "text", "text" => "second"}])

      assert {[], %{"error" => %{"code" => -32_600, "message" => message}}} =
               recv_response(client, 4)

      assert message =~ "in flight"

      finish(runner, "done")
      assert {_frames, %{"result" => _result}} = recv_response(client, 3)
    end

    test "refuses an unsupported content block and an empty prompt", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)

      assert %{"error" => %{"code" => -32_602, "message" => message}} =
               request(client, 3, "session/prompt", %{
                 "sessionId" => session_id,
                 "prompt" => [%{"type" => "image", "data" => "...", "mimeType" => "image/png"}]
               })

      assert message =~ "image"

      assert %{"error" => %{"code" => -32_602}} =
               request(client, 4, "session/prompt", %{
                 "sessionId" => session_id,
                 "prompt" => []
               })

      refute_receive {:turn_started, _msg, _runner}, 200
    end

    test "refuses a prompt for an unknown session", ctx do
      client = initialized(ctx)

      assert %{"error" => %{"code" => -32_602, "message" => message}} =
               request(client, 3, "session/prompt", %{
                 "sessionId" => "acp-deadbeef",
                 "prompt" => [%{"type" => "text", "text" => "hi"}]
               })

      assert message =~ "session"
    end

    test "two sessions run their turns in parallel under distinct conversations", ctx do
      client = initialized(ctx)
      first = new_session(client, 2)
      second = new_session(client, 3)

      prompt(client, 4, first, [%{"type" => "text", "text" => "one"}])
      prompt(client, 5, second, [%{"type" => "text", "text" => "two"}])

      # Both turns are running before either finishes — distinct FIFO lanes.
      # The lanes start concurrently, so :turn_started ARRIVAL ORDER is not the
      # prompt order. Correlate each runner to its session by chat_id (the
      # session id) instead of by position; binding them positionally finishes
      # one turn and then waits out the receive budget on the other ~50% of runs.
      assert_receive {:turn_started, msg_a, runner_a}, 5_000
      assert_receive {:turn_started, msg_b, runner_b}, 5_000
      assert msg_a.chat_id != msg_b.chat_id

      runners = %{msg_a.chat_id => runner_a, msg_b.chat_id => runner_b}
      first_runner = Map.fetch!(runners, first)
      second_runner = Map.fetch!(runners, second)

      finish(second_runner, "two done")
      assert {_frames, %{"result" => %{"stopReason" => "end_turn"}}} = recv_response(client, 5)

      finish(first_runner, "one done")
      assert {_frames, %{"result" => %{"stopReason" => "end_turn"}}} = recv_response(client, 4)
    end
  end

  describe "tool cards (§8.4)" do
    test "brackets a tool with tool_call and a completed update", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "run it"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      activity(runner, :provider_start)
      activity(runner, {:tool_start, "shell"})
      activity(runner, {:tool_finish, "shell", %{status: :ok}})
      finish(runner, "ran")

      {frames, _response} = recv_response(client, 3)
      [call, update] = Enum.filter(frames, &(update_kind(&1) in ~w(tool_call tool_call_update)))

      assert update_payload(call) == %{
               "sessionUpdate" => "tool_call",
               "toolCallId" => "t1",
               "title" => "shell",
               "kind" => "execute",
               "status" => "in_progress"
             }

      assert update_payload(update) == %{
               "sessionUpdate" => "tool_call_update",
               "toolCallId" => "t1",
               "status" => "completed"
             }
    end

    test "a failing tool reports the failed status", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "run it"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      activity(runner, {:tool_start, "web_search"})
      activity(runner, {:tool_finish, "web_search", %{status: :error}})
      finish(runner, "failed")

      {frames, _response} = recv_response(client, 3)
      [call, update] = Enum.filter(frames, &(update_kind(&1) in ~w(tool_call tool_call_update)))

      # `web_search` is a :network capability — a fetch-shaped card.
      assert update_payload(call)["kind"] == "fetch"
      assert update_payload(update)["status"] == "failed"
    end

    test "an unregistered tool name still renders a card", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "run it"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      activity(runner, {:tool_start, "not_a_registered_tool"})
      finish(runner, "ok")

      {frames, _response} = recv_response(client, 3)
      [call] = Enum.filter(frames, &(update_kind(&1) == "tool_call"))

      assert update_payload(call)["kind"] == "other"
    end
  end

  describe "cancel (§8.5)" do
    test "answers cancelled fast and fences every late frame", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "long job"}])
      assert_receive {:turn_started, msg, runner}, 5_000

      stream(runner, {:text_delta, "partial"})
      assert "agent_message_chunk" = update_kind(recv_frame(client))

      started = System.monotonic_time(:millisecond)
      notify(client, "session/cancel", %{"sessionId" => session_id})

      assert {[], %{"result" => %{"stopReason" => "cancelled"}}} = recv_response(client, 3)
      assert System.monotonic_time(:millisecond) - started < 1_000

      wait_until(fn -> not Process.alive?(runner) end)

      # Every late event for the fenced turn is dropped: nothing reaches the wire.
      late = inbound_message(msg)
      Acp.build_raw_stream_callback(late).({:text_delta, "late text"})
      Acp.build_activity_callback(late).({:tool_start, "shell"})
      Acp.build_turn_result(late).({:completed})

      assert {:error, :timeout} = :gen_tcp.recv(client, 0, 300)
    end

    test "$/cancel_request completes the in-flight prompt with -32800 exactly once", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "long job"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      notify(client, "$/cancel_request", %{"requestId" => 3})

      assert {[], %{"error" => %{"code" => -32_800}}} = recv_response(client, 3)
      wait_until(fn -> not Process.alive?(runner) end)
      assert {:error, :timeout} = :gen_tcp.recv(client, 0, 300)
    end

    test "a cancel for an idle session leaves the connection healthy", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)

      notify(client, "session/cancel", %{"sessionId" => session_id})

      assert %{"result" => _result} = request(client, 9, "initialize", %{"protocolVersion" => 1})
    end

    test "a bridge disconnect stops every in-flight turn", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "long job"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      :ok = :gen_tcp.close(client)

      wait_until(fn -> not Process.alive?(runner) end)
      assert Queue.status(ctx.queue).active_requests == 0
    end

    test "the peer deregisters its sessions when the connection dies", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)

      assert [{peer, _value}] = Registry.lookup(Acp.registry(), session_id)
      assert is_pid(peer)

      :ok = :gen_tcp.close(client)

      wait_until(fn -> Registry.lookup(Acp.registry(), session_id) == [] end)
    end
  end

  describe "turn failures (§4)" do
    test "an auth-shaped provider failure maps to -32000 Re-authenticate", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "hi"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      fail(runner, {:provider_error, "HTTP 401 Unauthorized: invalid api key"})

      {_frames, response} = recv_response(client, 3)

      assert response["error"]["code"] == -32_000
      assert String.starts_with?(response["error"]["message"], "Re-authenticate: ")
    end

    test "any other failure maps to -32603 without leaking the raw reason", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "hi"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      fail(runner, {:tool_exploded, %{trace: "s3cret-value-in-the-reason"}})

      {_frames, response} = recv_response(client, 3)

      assert response["error"]["code"] == -32_603
      refute response["error"]["message"] =~ "s3cret-value-in-the-reason"
      refute response["error"]["message"] =~ "tool_exploded"
    end
  end

  # A prompt is answered with a JSON-RPC error only while re-running it is safe.
  # An error invites the client to retry the whole turn (buzz-acp requeues a
  # batch up to ten times), so a turn that has ALREADY acted on the world is
  # reported terminal instead. The two tests above are the other half of this
  # asymmetry — a failure with NO effect keeps its -32603 / -32000 mapping.
  describe "the effect gate" do
    test "a failure after a SUCCESSFUL effectful tool answers end_turn, not an error", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "post the reply"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      {{frames, response}, log} =
        with_log(fn ->
          activity(runner, {:tool_start, "shell"})
          activity(runner, {:tool_finish, "shell", %{status: :ok}})
          fail(runner, {:provider_error, :transport_closed})
          recv_response(client, 3)
        end)

      assert response["result"] == %{"stopReason" => "end_turn"}
      refute Map.has_key?(response, "error")
      assert Enum.all?(frames, &(not Map.has_key?(&1, "error")))
      # Exactly one terminal frame: nothing follows the end_turn.
      assert {:error, :timeout} = :gen_tcp.recv(client, 0, 300)

      # An end_turn must never hide the failure from the daemon log.
      assert log =~ "transport_closed"
      assert log =~ "effect"
    end

    test "a failure after a READ-ONLY tool still answers -32603 — the rule is 'acted'", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "read the log"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      {{frames, response}, log} =
        with_log(fn ->
          activity(runner, {:tool_start, "file_read"})
          activity(runner, {:tool_finish, "file_read", %{status: :ok}})
          fail(runner, {:provider_error, :transport_closed})
          recv_response(client, 3)
        end)

      # Self-verifying: the card the client saw really was a read.
      [call] = Enum.filter(frames, &(update_kind(&1) == "tool_call"))
      assert update_payload(call)["kind"] == "read"

      assert response["error"]["code"] == -32_603
      assert log =~ "transport_closed"
    end

    test "a failure after a FAILED effectful tool answers -32603 — it performed nothing", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "post the reply"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      {{_frames, response}, log} =
        with_log(fn ->
          activity(runner, {:tool_start, "shell"})
          activity(runner, {:tool_finish, "shell", %{status: :error}})
          fail(runner, {:provider_error, :transport_closed})
          recv_response(client, 3)
        end)

      assert response["error"]["code"] == -32_603
      assert log =~ "transport_closed"
    end

    test "a CRASHED turn that already acted answers end_turn", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "post the reply"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      {{_frames, response}, log} =
        with_log(fn ->
          activity(runner, {:tool_start, "shell"})
          activity(runner, {:tool_finish, "shell", %{status: :ok}})
          send(runner, :crash)
          recv_response(client, 3)
        end)

      assert response["result"] == %{"stopReason" => "end_turn"}
      assert log =~ "crashed"
      assert log =~ "effect"
    end

    test "an UNREGISTERED tool counts as an effect — an unknown capability fails closed", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)
      prompt(client, 3, session_id, [%{"type" => "text", "text" => "do the thing"}])
      assert_receive {:turn_started, _msg, runner}, 5_000

      {{frames, response}, _log} =
        with_log(fn ->
          activity(runner, {:tool_start, "not_a_registered_tool"})
          activity(runner, {:tool_finish, "not_a_registered_tool", %{status: :ok}})
          fail(runner, {:provider_error, :transport_closed})
          recv_response(client, 3)
        end)

      [call] = Enum.filter(frames, &(update_kind(&1) == "tool_call"))
      assert update_payload(call)["kind"] == "other"
      assert response["result"] == %{"stopReason" => "end_turn"}
    end

    test "the ledger is per turn: a later clean turn still errors on its own failure", ctx do
      client = initialized(ctx)
      session_id = new_session(client, 2)

      prompt(client, 3, session_id, [%{"type" => "text", "text" => "post the reply"}])
      assert_receive {:turn_started, _msg, first}, 5_000

      with_log(fn ->
        activity(first, {:tool_start, "shell"})
        activity(first, {:tool_finish, "shell", %{status: :ok}})
        fail(first, {:provider_error, :transport_closed})
        assert {_frames, %{"result" => %{"stopReason" => "end_turn"}}} = recv_response(client, 3)
      end)

      prompt(client, 4, session_id, [%{"type" => "text", "text" => "again"}])
      assert_receive {:turn_started, _msg, second}, 5_000

      with_log(fn ->
        fail(second, {:provider_error, :transport_closed})
        assert {_frames, %{"error" => %{"code" => -32_603}}} = recv_response(client, 4)
      end)
    end
  end

  # §17: the client's presented credentials are a CONNECTED PROVIDER, not session
  # state. Hello persists them; every turn resolves them from the store at
  # message-build time, so one source answers a live turn and a continuation
  # alike (§17.1). The two halves of a sanitizer test are both kept (the
  # 2026-07-26 lesson): what the env must NOT carry, and that what it does carry
  # is sufficient to post.
  describe "client identity (§17)" do
    test "a valid nsec persists a record and the turn carries the identity keys", ctx do
      client = connect(ctx) |> handshake(buzz_env()) |> initialize()

      assert File.exists?(Path.join(ctx.identity_dir, "#{@public_hex}.json"))

      env = session_env_of(client, 10)

      assert env == %{
               "BUZZ_PRIVATE_KEY" => @nsec,
               "BUZZ_RELAY_URL" => "wss://relay.test",
               "PATH" => "/fake/bin:/usr/bin"
             }

      # The fidelity half: this env can actually sign and post, which is what
      # re-opens the harness family on this surface (§17.6(a)).
      assert Identity.posting_capable?(env)
    end

    test "a malformed nsec persists nothing and strips both signing keys", ctx do
      client =
        connect(ctx)
        |> handshake(buzz_env(%{"BUZZ_PRIVATE_KEY" => "nsec1thisisnotarealkey"}))
        |> initialize()

      assert records(ctx) == []

      env = session_env_of(client, 10)

      refute Map.has_key?(env, "BUZZ_PRIVATE_KEY")
      refute Map.has_key?(env, "NOSTR_PRIVATE_KEY")
      refute Identity.posting_capable?(env)
      # The rest of the ambient allowlist survives, so ordinary work still runs.
      assert env["PATH"] == "/fake/bin:/usr/bin"
      assert env["BUZZ_RELAY_URL"] == "wss://relay.test"
    end

    test "a hello with no Buzz keys persists nothing and keeps today's ambient env", ctx do
      client =
        connect(ctx)
        |> handshake(%{
          "PATH" => "/fake/bin:/usr/bin",
          "GIT_TERMINAL_PROMPT" => "0",
          "OPENAI_API_KEY" => "sk-must-not-travel",
          "HOME" => "/Users/operator"
        })
        |> initialize()

      assert records(ctx) == []

      assert session_env_of(client, 10) == %{
               "PATH" => "/fake/bin:/usr/bin",
               "GIT_TERMINAL_PROMPT" => "0"
             }
    end

    # §17.2: the Peer binds an id only after the store said :ok. A key whose
    # record is not on disk would advertise the harness and then have nothing for
    # the continuation to read — the exact outcome §16.1 rejected.
    test "a store write failure downgrades the connection before its first turn", ctx do
      File.write!(ctx.identity_dir, "not a directory")

      {client, log} =
        with_log(fn -> connect(ctx) |> handshake(buzz_env()) |> initialize() end)

      assert log =~ "Acp.Peer"
      assert log =~ "could not persist the identity"
      assert log =~ @npub

      env = session_env_of(client, 10)

      refute Map.has_key?(env, "BUZZ_PRIVATE_KEY")
      refute Identity.posting_capable?(env)
      assert env["PATH"] == "/fake/bin:/usr/bin"
    end

    # §17.3: the connection TRANSITIONS to identity-less — it does not re-read,
    # so the state cannot flap back when the record returns.
    test "a record deleted mid-connection drops the connection to identity-less for good", ctx do
      client = connect(ctx) |> handshake(buzz_env()) |> initialize()
      assert Identity.posting_capable?(session_env_of(client, 10))

      SafeRm.rm!(record_path(ctx))

      {env, log} = with_log(fn -> session_env_of(client, 20) end)

      refute Identity.posting_capable?(env)
      assert log =~ @npub
      assert log =~ record_path(ctx)

      # The record comes back; the connection does not.
      assert {:ok, :created} = IdentityStore.upsert(Identity.new(buzz_env()))
      assert File.exists?(record_path(ctx))

      {later, later_log} = with_log(fn -> session_env_of(client, 30) end)

      refute Identity.posting_capable?(later)
      refute later_log =~ @npub
    end

    # Three kinds, three messages, never collapsed (§17.3, the M28 lesson).
    test "a missing, a quarantined and a refused record are named apart", ctx do
      missing = drop_reason(ctx, fn path -> SafeRm.rm!(path) end)
      quarantined = drop_reason(ctx, fn path -> File.write!(path, "{not json") end)
      refused = drop_reason(ctx, fn path -> File.chmod!(path, 0o644) end)

      assert length(Enum.uniq([missing, quarantined, refused])) == 3
      assert missing =~ "no record"
      assert quarantined =~ "quarantined"
      assert refused =~ "chmod 600"
    end

    # The one-source property (§17.1), asserted directly: a rotation another
    # connection persisted is visible to THIS connection's next turn, which can
    # only be true if the turn reads the store rather than connection state.
    test "a rotation persisted by a second connection reaches the first's next turn", ctx do
      first = connect(ctx) |> handshake(buzz_env()) |> initialize()
      assert session_env_of(first, 10)["BUZZ_RELAY_URL"] == "wss://relay.test"

      second =
        connect(ctx)
        |> handshake(buzz_env(%{"BUZZ_RELAY_URL" => "wss://moved.test"}))
        |> initialize()

      assert session_env_of(second, 10)["BUZZ_RELAY_URL"] == "wss://moved.test"
      assert session_env_of(first, 20)["BUZZ_RELAY_URL"] == "wss://moved.test"
    end

    test "two connections with different identities never see each other's env", ctx do
      first = connect(ctx) |> handshake(buzz_env()) |> initialize()

      second =
        connect(ctx)
        |> handshake(buzz_env(%{"BUZZ_PRIVATE_KEY" => @other_nsec}))
        |> initialize()

      assert session_env_of(first, 10)["BUZZ_PRIVATE_KEY"] == @nsec
      assert session_env_of(second, 10)["BUZZ_PRIVATE_KEY"] == @other_nsec
      assert length(records(ctx)) == 2
    end
  end

  describe "framing limits (§11)" do
    test "a line over the protocol cap closes the connection", ctx do
      client = handshake(connect(ctx))

      # One byte over the cap, no newline — see the hello case above.
      :ok = :gen_tcp.send(client, String.duplicate("a", Wire.max_line_bytes() + 1))

      assert closed?(client, 5_000)
    end
  end

  # --- client helpers ---

  defp connect(ctx) do
    {:ok, socket} =
      :gen_tcp.connect({:local, to_charlist(ctx.socket_path)}, 0, [
        :binary,
        {:active, false},
        {:packet, :line}
      ])

    socket
  end

  defp handshake(client, env \\ %{}) do
    :ok = send_json(client, %{"fermix_bridge" => 1, "app_version" => "0.0.0", "env" => env})
    %{"fermix_bridge_ack" => %{"status" => "ok"}} = recv_frame(client)
    client
  end

  # A Buzz bridge's hello: the allowlisted credentials plus the operator's own
  # world, which must never survive the filter.
  defp buzz_env(overrides \\ %{}) do
    Map.merge(
      %{
        "BUZZ_PRIVATE_KEY" => @nsec,
        "BUZZ_RELAY_URL" => "wss://relay.test",
        "PATH" => "/fake/bin:/usr/bin",
        "OPENAI_API_KEY" => "sk-must-not-travel",
        "HOME" => "/Users/operator"
      },
      overrides
    )
  end

  # Drive one whole turn on `client` and hand back the env it carried. Each call
  # opens its own session, so `id` only has to be unique within the connection.
  defp session_env_of(client, id) do
    session_id = new_session(client, id)
    prompt(client, id + 1, session_id, [%{"type" => "text", "text" => "post it"}])

    assert_receive {:turn_started, msg, runner}, 5_000
    finish(runner, "posted")
    assert {_frames, %{"result" => _result}} = recv_response(client, id + 1)

    msg.session_env
  end

  # Break a bound connection's record with `damage`, then return the warning line
  # its next turn logged — the message an operator has to read.
  defp drop_reason(ctx, damage) do
    client = connect(ctx) |> handshake(buzz_env()) |> initialize()
    assert Identity.posting_capable?(session_env_of(client, 10))

    damage.(record_path(ctx))
    {_env, log} = with_log(fn -> session_env_of(client, 20) end)

    log
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ "Acp.Peer"))
    |> Enum.join(" ")
  end

  defp record_path(ctx), do: Path.join(ctx.identity_dir, "#{@public_hex}.json")

  defp records(ctx) do
    case File.ls(ctx.identity_dir) do
      {:ok, entries} -> Enum.filter(entries, &String.ends_with?(&1, ".json"))
      {:error, :enoent} -> []
    end
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)

  defp initialize(client) do
    %{"result" => %{"protocolVersion" => 1}} =
      request(client, 1, "initialize", %{"protocolVersion" => 2})

    client
  end

  defp initialized(ctx), do: ctx |> connect() |> handshake() |> initialize()

  defp new_session(client, id) do
    %{"result" => %{"sessionId" => session_id}} =
      request(client, id, "session/new", %{
        "cwd" => @cwd,
        "mcpServers" => [],
        "_meta" => %{"sessionTitle" => "Fermix · #engineering"}
      })

    session_id
  end

  defp prompt(client, id, session_id, blocks) do
    notify_raw(client, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "session/prompt",
      "params" => %{"sessionId" => session_id, "prompt" => blocks}
    })
  end

  defp request(client, id, method, params) do
    notify_raw(client, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    {_frames, response} = recv_response(client, id)
    response
  end

  defp notify(client, method, params) do
    notify_raw(client, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp notify_raw(client, frame), do: :ok = send_json(client, frame)

  defp send_json(client, payload), do: :gen_tcp.send(client, Jason.encode!(payload) <> "\n")

  defp recv_frame(client, timeout \\ 2_000) do
    case :gen_tcp.recv(client, 0, timeout) do
      {:ok, line} -> Jason.decode!(line)
      {:error, reason} -> flunk("expected a frame, got #{inspect(reason)}")
    end
  end

  # Reads frames until the response to `id`, returning everything that came
  # before it. Bounded: a missing response fails on the recv timeout.
  defp recv_response(client, id, acc \\ [], attempts \\ 200)

  defp recv_response(_client, id, _acc, 0), do: flunk("no response for id #{inspect(id)}")

  defp recv_response(client, id, acc, attempts) do
    frame = recv_frame(client, 5_000)

    if frame["id"] == id and not Map.has_key?(frame, "method") do
      {Enum.reverse(acc), frame}
    else
      recv_response(client, id, [frame | acc], attempts - 1)
    end
  end

  defp closed?(client, timeout \\ 1_000) do
    :gen_tcp.recv(client, 0, timeout) == {:error, :closed}
  end

  defp update_payload(frame), do: get_in(frame, ["params", "update"])
  defp update_kind(frame), do: frame |> update_payload() |> then(&(&1 && &1["sessionUpdate"]))
  defp updates(frames), do: Enum.map(frames, &update_kind/1)

  defp chunk_texts(frames) do
    frames
    |> Enum.filter(&(update_kind(&1) == "agent_message_chunk"))
    |> Enum.map(&get_in(&1, ["params", "update", "content", "text"]))
  end

  # --- turn helpers ---

  defp stream(runner, event), do: send(runner, {:stream, event})
  defp activity(runner, event), do: send(runner, {:activity, event})
  defp finish(runner, response), do: send(runner, {:finish, response})
  defp fail(runner, reason), do: send(runner, {:fail, reason})

  # Rebuilds the inbound `Message` the adapter closures were built from, so a
  # late event can be pushed through the REAL closure path after the fence closed.
  defp inbound_message(core_msg) do
    struct!(
      Message,
      Map.take(core_msg, [:id, :content, :sender, :channel, :chat_id, :reply_target, :metadata])
    )
  end

  defp wait_until(fun, attempts \\ 150)

  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
