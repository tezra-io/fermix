defmodule FermixCore.Realtime.XAIRealtimeClientTest do
  use ExUnit.Case, async: true

  alias FermixCore.Net.Egress
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.XAIRealtimeClient, as: Client

  # A struct literal rather than `Config.normalize/1`: the builder reads the
  # engine and the voice, and nothing else about how a config is normalized.
  @grok %Config{engine: "xai_realtime", provider: "xai", model: "grok-voice-3.0", voice: "eve"}

  describe "connection" do
    test "the model rides the URL, and the key is the only header" do
      assert Client.url("grok-voice-3.0") == "wss://api.x.ai/v1/realtime?model=grok-voice-3.0"
      assert Client.url("a b&c") == "wss://api.x.ai/v1/realtime?model=a+b%26c"
      assert Client.headers("xai-test") == [{"Authorization", "Bearer xai-test"}]
    end

    test "an empty key or model is refused before anything is built" do
      assert_raise FunctionClauseError, fn -> Client.headers("") end
      assert_raise FunctionClauseError, fn -> Client.url("") end
    end

    test "verifies the SpaceXAI peer instead of taking WebSockex's insecure default" do
      assert {:ok, opts} =
               Client.start_options(Client.url("grok-voice-3.0"), Client.headers("xai-test"))

      # Without :ssl_options WebSockex connects with verify: :verify_none, and
      # the API key in the headers goes to whoever answered.
      ssl_options = Keyword.fetch!(opts, :ssl_options)

      assert ssl_options[:verify] == :verify_peer
      assert ssl_options[:server_name_indication] == ~c"api.x.ai"
      assert {"Authorization", "Bearer xai-test"} in opts[:extra_headers]
      assert opts[:handshake_timeout] == Client.handshake_timeout_ms()
      assert Client.handshake_timeout_ms() == 5_000
    end

    test "refuses a URL with no host rather than dialing a peer it cannot verify" do
      assert Client.start_options("api.x.ai/v1/realtime", []) == {:error, :ws_url_without_host}
      assert Client.start_options("wss:///v1/realtime", []) == {:error, :ws_url_without_host}
    end

    # The socket cannot tunnel, so behind a proxy it refuses before it dials.
    test "refuses a proxied destination before it dials" do
      assert Client.start_link(
               url: Client.url("grok-voice-3.0"),
               headers: [],
               parent: self(),
               egress: Egress.new(proxy: "http://proxy.test:3128")
             ) == {:error, :proxy_unsupported_transport}
    end

    test "client item ids are prefixed and unique" do
      ids = for _ <- 1..50, do: Client.new_item_id()

      assert Enum.all?(ids, &String.starts_with?(&1, "fx_"))
      assert length(Enum.uniq(ids)) == 50
    end
  end

  describe "builders" do
    test "session.update configures voice, VAD, reasoning and PCM, and nothing hosted" do
      tool = %{type: "function", name: "fermix_task", parameters: %{"type" => "object"}}

      assert Client.session_update_event(@grok, "be brief", [tool]) == %{
               type: "session.update",
               session: %{
                 instructions: "be brief",
                 voice: "eve",
                 turn_detection: %{type: "server_vad"},
                 reasoning: %{effort: "high"},
                 resumption: %{enabled: false},
                 tools: [tool],
                 audio: %{
                   input: %{format: %{type: "audio/pcm", rate: 24_000}},
                   output: %{format: %{type: "audio/pcm", rate: 24_000}}
                 }
               }
             }
    end

    # The model rides the URL; an idle timer would make the vendor start
    # check-in turns of its own.
    test "session.update carries no model and no idle timeout" do
      %{session: session} = Client.session_update_event(@grok, "ins", [])

      refute Map.has_key?(session, :model)
      refute Map.has_key?(session.turn_detection, :idle_timeout_ms)
    end

    test "session.update refuses a config for another engine" do
      openai = %Config{engine: "openai_live", voice: "marin"}

      assert_raise FunctionClauseError, fn -> Client.session_update_event(openai, "ins", []) end
    end

    test "an audio append carries base64 PCM and refuses an odd byte count" do
      assert Client.audio_append_event(<<1, 2, 3, 4>>) == %{
               type: "input_audio_buffer.append",
               audio: Base.encode64(<<1, 2, 3, 4>>)
             }

      assert_raise FunctionClauseError, fn -> Client.audio_append_event(<<1, 2, 3>>) end
    end

    test "a context item keeps its client id, and its part type follows the role" do
      for {role, part} <- [
            {"system", "input_text"},
            {"user", "input_text"},
            {"assistant", "text"}
          ] do
        assert Client.context_item_event("fx_1", role, "earlier words") == %{
                 type: "conversation.item.create",
                 item: %{
                   id: "fx_1",
                   type: "message",
                   role: role,
                   content: [%{type: part, text: "earlier words"}]
                 }
               }
      end

      assert_raise FunctionClauseError, fn -> Client.context_item_event("fx_1", "tool", "x") end
      assert_raise FunctionClauseError, fn -> Client.context_item_event("", "user", "x") end
    end

    test "a function output answers its call under a client item id" do
      assert Client.function_output_event("fx_2", "call_1", ~s({"ok":true})) == %{
               type: "conversation.item.create",
               item: %{
                 id: "fx_2",
                 type: "function_call_output",
                 call_id: "call_1",
                 output: ~s({"ok":true})
               }
             }

      assert_raise FunctionClauseError, fn -> Client.function_output_event("fx_2", "", "{}") end
    end

    test "response.create is tagged with the continuation it answers" do
      assert Client.response_create_event("c1") == %{
               type: "response.create",
               response: %{metadata: %{"fermix_continuation" => "c1"}}
             }

      # The vendor caps a metadata value at 512 characters.
      assert Client.response_create_event(String.duplicate("c", 512))
      too_long = String.duplicate("c", 513)
      assert_raise FunctionClauseError, fn -> Client.response_create_event(too_long) end
      assert_raise FunctionClauseError, fn -> Client.response_create_event("") end
    end

    test "cancel names the response, and truncate names the item, part and offset" do
      assert Client.response_cancel_event("resp_1") == %{
               type: "response.cancel",
               response_id: "resp_1"
             }

      assert Client.truncate_event("msg_4", 0, 1_500) == %{
               type: "conversation.item.truncate",
               item_id: "msg_4",
               content_index: 0,
               audio_end_ms: 1_500
             }

      assert_raise FunctionClauseError, fn -> Client.truncate_event("msg_4", -1, 0) end
      assert_raise FunctionClauseError, fn -> Client.truncate_event("msg_4", 0, -1) end
    end
  end

  describe "decode_server_event/1" do
    test "session, conversation and VAD events" do
      assert decode(%{"type" => "session.created", "session" => %{"id" => "sess_1"}}) ==
               {:ok, {:session_created, "sess_1"}}

      assert decode(%{"type" => "conversation.created", "conversation" => %{"id" => "conv_1"}}) ==
               {:ok, {:conversation_created, "conv_1"}}

      assert decode(%{
               "type" => "session.updated",
               "session" => %{"voice" => "eve", "turn_detection" => %{"type" => "server_vad"}}
             }) == {:ok, {:session_updated, %{turn_detection: "server_vad", voice: "eve"}}}

      # `null` turn detection means manual turns; both fields are optional.
      assert decode(%{"type" => "session.updated", "session" => %{"turn_detection" => nil}}) ==
               {:ok, {:session_updated, %{turn_detection: nil, voice: nil}}}

      assert decode(%{"type" => "input_audio_buffer.speech_started", "item_id" => "msg_3"}) ==
               {:ok, {:speech_started, "msg_3"}}

      assert decode(%{"type" => "input_audio_buffer.speech_stopped", "item_id" => "msg_3"}) ==
               {:ok, {:speech_stopped, "msg_3"}}
    end

    test "conversation items and transcripts" do
      assert decode(%{
               "type" => "conversation.item.added",
               "item" => %{"id" => "fx_1", "type" => "message", "role" => "user"}
             }) == {:ok, {:item_added, %{id: "fx_1", type: "message", role: "user"}}}

      assert decode(%{
               "type" => "conversation.item.added",
               "item" => %{"id" => "fc_1", "type" => "function_call"}
             }) == {:ok, {:item_added, %{id: "fc_1", type: "function_call", role: nil}}}

      assert decode(%{
               "type" => "conversation.item.input_audio_transcription.completed",
               "item_id" => "msg_3",
               "transcript" => "hello there"
             }) == {:ok, {:user_transcript, "msg_3", "hello there"}}

      assert decode(%{
               "type" => "conversation.item.truncated",
               "item_id" => "msg_4",
               "transcript" => "Hello! I'm doing"
             }) == {:ok, {:item_truncated, "msg_4", "Hello! I'm doing"}}

      assert decode(%{"type" => "conversation.item.truncated", "item_id" => "msg_4"}) ==
               {:ok, {:item_truncated, "msg_4", nil}}
    end

    test "response lifecycle and audio" do
      assert decode(%{
               "type" => "response.created",
               "response" => %{"id" => "resp_1", "metadata" => %{"fermix_continuation" => "c1"}}
             }) == {:ok, {:response_created, "resp_1", %{"fermix_continuation" => "c1"}}}

      # A response the vendor's own VAD started echoes `null` metadata.
      assert decode(%{
               "type" => "response.created",
               "response" => %{"id" => "resp_2", "metadata" => nil}
             }) == {:ok, {:response_created, "resp_2", nil}}

      for type <- ["response.output_audio.delta", "response.audio.delta"] do
        assert decode(%{
                 "type" => type,
                 "response_id" => "resp_1",
                 "item_id" => "msg_8",
                 "content_index" => 0,
                 "delta" => "AAAA"
               }) == {:ok, {:audio_delta, "resp_1", "msg_8", 0, "AAAA"}}
      end

      assert decode(%{
               "type" => "response.output_audio_transcript.delta",
               "response_id" => "resp_1",
               "item_id" => "msg_8",
               "delta" => "Hello! I'm"
             }) == {:ok, {:assistant_transcript_delta, "resp_1", "msg_8", "Hello! I'm"}}

      assert decode(%{
               "type" => "response.output_audio_transcript.done",
               "response_id" => "resp_1",
               "item_id" => "msg_8"
             }) == {:ok, {:assistant_transcript_done, "resp_1", "msg_8"}}

      assert decode(%{
               "type" => "response.done",
               "response" => %{
                 "id" => "resp_1",
                 "status" => "completed",
                 "usage" => %{"input_tokens" => 3}
               }
             }) == {:ok, {:response_done, "resp_1", "completed", %{"input_tokens" => 3}}}

      assert decode(%{
               "type" => "response.done",
               "response" => %{"id" => "resp_1", "status" => "cancelled"}
             }) == {:ok, {:response_done, "resp_1", "cancelled", nil}}
    end

    test "a completed function call carries every id, its name and its arguments" do
      assert decode(function_call_event()) ==
               {:ok,
                {:function_call,
                 %{
                   response_id: "resp_1",
                   item_id: "msg_9",
                   call_id: "call_1",
                   name: "fermix_task",
                   arguments: ~s({"action":"submit"})
                 }}}
    end

    test "a vendor error carries its fields as strings or nil" do
      assert decode(%{
               "type" => "error",
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_audio_format",
                 "message" => "Audio format not supported.",
                 "param" => "audio"
               }
             }) ==
               {:ok,
                {:error,
                 %{
                   type: "invalid_request_error",
                   code: "invalid_audio_format",
                   message: "Audio format not supported.",
                   param: "audio"
                 }}}

      assert decode(%{"type" => "error", "error" => %{"type" => "timeout", "code" => 42}}) ==
               {:ok, {:error, %{type: "timeout", code: nil, message: nil, param: nil}}}
    end

    test "a vendor error message is bounded to 500 bytes without splitting a codepoint" do
      long = String.duplicate("é", 400)

      assert {:ok, {:error, %{message: message}}} =
               decode(%{"type" => "error", "error" => %{"message" => long}})

      assert byte_size(message) == 500
      assert String.valid?(message)
    end

    test "every type the session has no use for is unhandled, by name only" do
      for type <- [
            "response.output_audio.done",
            "response.content_part.added",
            "response.content_part.done",
            "response.output_item.added",
            "response.output_item.done",
            "response.function_call_arguments.delta",
            "input_audio_buffer.committed",
            "input_audio_buffer.cleared",
            "conversation.item.deleted",
            "conversation.item.input_audio_transcription.updated",
            "response.text.delta",
            "response.output_text.delta",
            "mcp_list_tools.completed",
            "a.type.no.one.has.seen"
          ] do
        assert decode(%{"type" => type, "anything" => %{"at" => "all"}}) ==
                 {:ok, {:unhandled, type}}
      end
    end

    test "a known event missing a required field names the event and the field" do
      cases = [
        {%{"type" => "session.created"}, "session.id"},
        {%{"type" => "session.created", "session" => %{"id" => ""}}, "session.id"},
        {%{"type" => "conversation.created", "conversation" => %{}}, "conversation.id"},
        {%{"type" => "session.updated"}, "session"},
        {%{"type" => "input_audio_buffer.speech_started"}, "item_id"},
        {%{"type" => "input_audio_buffer.speech_stopped", "item_id" => 7}, "item_id"},
        {%{"type" => "conversation.item.added", "item" => %{"type" => "message"}}, "item.id"},
        {%{"type" => "conversation.item.added", "item" => %{"id" => "fx_1"}}, "item.type"},
        {%{"type" => "conversation.item.input_audio_transcription.completed", "item_id" => "m"},
         "transcript"},
        {%{"type" => "conversation.item.truncated"}, "item_id"},
        {%{"type" => "response.created", "response" => %{}}, "response.id"},
        {%{"type" => "response.done", "response" => %{"id" => "resp_1"}}, "response.status"},
        {%{"type" => "response.done", "response" => %{"status" => "completed"}}, "response.id"},
        {%{"type" => "error"}, "error"},
        {%{"type" => "error", "error" => "boom"}, "error"}
      ]

      for {event, field} <- cases do
        assert decode(event) == {:error, {:malformed_event, event["type"], field}},
               "#{inspect(event)} should be malformed at #{field}"
      end
    end

    test "an audio delta needs both ids, a non-negative part index and the audio" do
      good = %{
        "type" => "response.output_audio.delta",
        "response_id" => "resp_1",
        "item_id" => "msg_8",
        "content_index" => 0,
        "delta" => "AAAA"
      }

      for {field, bad} <- [
            {"response_id", nil},
            {"item_id", ""},
            {"content_index", -1},
            {"content_index", 1.0},
            {"delta", nil}
          ] do
        event = Map.put(good, field, bad)

        assert decode(event) ==
                 {:error, {:malformed_event, "response.output_audio.delta", field}}
      end
    end

    test "a function call missing any id, its name or its arguments is malformed" do
      for field <- ["response_id", "item_id", "call_id", "name", "arguments"] do
        event = Map.delete(function_call_event(), field)

        assert decode(event) ==
                 {:error, {:malformed_event, "response.function_call_arguments.done", field}}
      end
    end

    test "transcript events need both ids, and a delta its text" do
      delta = %{
        "type" => "response.output_audio_transcript.delta",
        "response_id" => "resp_1",
        "item_id" => "msg_8",
        "delta" => "hi"
      }

      assert decode(Map.delete(delta, "delta")) ==
               {:error, {:malformed_event, "response.output_audio_transcript.delta", "delta"}}

      done = %{"type" => "response.output_audio_transcript.done", "response_id" => "resp_1"}

      assert decode(done) ==
               {:error, {:malformed_event, "response.output_audio_transcript.done", "item_id"}}
    end

    # An optional field may be absent or null, but a value of the wrong type is
    # a protocol error, not something to read around — including a path that
    # runs through a non-object.
    test "an optional field of the wrong type is malformed, never a crash" do
      assert decode(%{"type" => "session.updated", "session" => %{"voice" => 3}}) ==
               {:error, {:malformed_event, "session.updated", "session.voice"}}

      assert decode(%{"type" => "session.updated", "session" => %{"turn_detection" => "vad"}}) ==
               {:error, {:malformed_event, "session.updated", "session.turn_detection.type"}}

      assert decode(%{"type" => "session.created", "session" => "sess_1"}) ==
               {:error, {:malformed_event, "session.created", "session.id"}}

      assert decode(%{
               "type" => "response.created",
               "response" => %{"id" => "resp_1", "metadata" => "c1"}
             }) == {:error, {:malformed_event, "response.created", "response.metadata"}}

      assert decode(%{
               "type" => "response.done",
               "response" => %{"id" => "resp_1", "status" => "completed", "usage" => []}
             }) == {:error, {:malformed_event, "response.done", "response.usage"}}

      assert decode(%{
               "type" => "conversation.item.added",
               "item" => %{"id" => "fx_1", "type" => "message", "role" => false}
             }) == {:error, {:malformed_event, "conversation.item.added", "item.role"}}
    end

    test "an object with no string type is invalid, as a bounded description" do
      assert {:error, {:invalid_server_event, shown}} = decode(%{"no" => "type"})
      assert shown == inspect(%{"no" => "type"})

      assert {:error, {:invalid_server_event, _shown}} = decode(%{"type" => 5})
    end
  end

  # The session acts only on the socket it currently uses, so every message a
  # socket sends names it. `handle_frame/2` runs inside the socket process, where
  # `self()` is the socket.
  describe "messages to the session name the socket" do
    test "a decoded event carries the socket pid" do
      me = self()
      frame = ~s({"type":"session.created","session":{"id":"sess_1"}})

      assert {:ok, _state} = Client.handle_frame({:text, frame}, %{parent: me})

      assert_received {:xai_realtime_event, ^me, {:session_created, "sess_1"}}
    end

    test "a malformed event is an error that carries the socket pid" do
      me = self()

      assert {:ok, _state} =
               Client.handle_frame({:text, ~s({"type":"session.created"})}, %{parent: me})

      assert_received {:xai_realtime_error, ^me,
                       {:malformed_event, "session.created", "session.id"}}
    end

    test "a frame that is not JSON is an error that carries the socket pid" do
      me = self()

      assert {:ok, _state} = Client.handle_frame({:text, "not json"}, %{parent: me})

      assert_received {:xai_realtime_error, ^me, {:decode_failed, _message}}
    end

    test "JSON that is not an object is a bounded error that carries the socket pid" do
      me = self()
      huge = Jason.encode!([String.duplicate("x", 10_000) | Enum.to_list(1..10_000)])

      for payload <- [~s([1]), ~s("text"), ~s(42), ~s(null), huge] do
        assert {:ok, _state} = Client.handle_frame({:text, payload}, %{parent: me})
        assert_received {:xai_realtime_error, ^me, {:invalid_server_event, shown}}
        assert byte_size(shown) < 200
      end
    end

    # A frame past the bound is reported by size and never parsed: it is the
    # same report whether or not its bytes would have decoded.
    test "a frame over the bound is reported by its size, never decoded" do
      me = self()
      bound = Client.max_frame_bytes()
      assert bound == 1_048_576

      padding = String.duplicate("x", bound)
      frame = ~s({"type":"session.created","session":{"id":"sess_1"},"pad":") <> padding <> ~s("})

      assert {:ok, _state} = Client.handle_frame({:text, frame}, %{parent: me})

      size = byte_size(frame)
      assert_received {:xai_realtime_error, ^me, {:frame_too_large, ^size}}
      refute_received {:xai_realtime_event, ^me, _decoded}

      at_bound = ~s({"type":"x","pad":") <> String.duplicate("x", bound - 21) <> ~s("})
      assert byte_size(at_bound) == bound
      assert {:ok, _state} = Client.handle_frame({:text, at_bound}, %{parent: me})
      assert_received {:xai_realtime_event, ^me, {:unhandled, "x"}}
    end

    test "a binary frame is an error, never decoded as audio" do
      me = self()

      assert {:ok, _state} = Client.handle_frame({:binary, <<0, 1, 2, 3>>}, %{parent: me})

      assert_received {:xai_realtime_error, ^me, :unexpected_binary_frame}
    end

    # The socket's EXIT is the one signal that it died. A second notice from a
    # disconnect callback would race the EXIT of the socket that replaced it.
    test "a disconnect sends the session nothing" do
      status = %{reason: {:remote, :closed}, conn: nil, attempt_number: 1}

      assert {:ok, _state} = Client.handle_disconnect(status, %{parent: self()})

      assert Process.info(self(), :messages) == {:messages, []}
    end

    # The session's one liveness signal, over a real WebSockex connection on
    # loopback: the link `start_link/1` makes.
    test "a real socket's events name it, and its death reaches the caller only as its EXIT" do
      Process.flag(:trap_exit, true)
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)
      server = Task.async(fn -> serve_one_frame_then_drop(listen) end)

      assert {:ok, socket} =
               Client.start_link(url: "ws://127.0.0.1:#{port}/", headers: [], parent: self())

      send(server.pid, :drop)

      assert_receive {:xai_realtime_event, ^socket, {:session_created, "sess_1"}}
      assert_receive {:EXIT, ^socket, {:remote, :closed}}
      assert :ok = Task.await(server)
      assert_receive {:EXIT, _task, :normal}
      :ok = :gen_tcp.close(listen)
      assert Process.info(self(), :messages) == {:messages, []}
    end
  end

  defp decode(event), do: Client.decode_server_event(event)

  defp function_call_event do
    %{
      "type" => "response.function_call_arguments.done",
      "response_id" => "resp_1",
      "item_id" => "msg_9",
      "output_index" => 0,
      "call_id" => "call_1",
      "name" => "fermix_task",
      "arguments" => ~s({"action":"submit"})
    }
  end

  # Accepts one WebSocket client on `listen`, completes its handshake, and on
  # `:drop` sends it one text frame and closes the TCP connection without a close
  # frame, as a dropped network does.
  defp serve_one_frame_then_drop(listen) do
    {:ok, conn} = :gen_tcp.accept(listen, 5_000)
    [_line, key] = Regex.run(~r/sec-websocket-key:\s*(\S+)/i, read_upgrade_request(conn, ""))
    accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

    :ok =
      :gen_tcp.send(conn, [
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n",
        "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
      ])

    receive do
      :drop -> :ok
    after
      5_000 -> raise "the test never asked the server to drop the socket"
    end

    payload = ~s({"type":"session.created","session":{"id":"sess_1"}})
    :ok = :gen_tcp.send(conn, <<1::1, 0::3, 1::4, 0::1, byte_size(payload)::7, payload::binary>>)
    :gen_tcp.close(conn)
  end

  @upgrade_reads 10

  defp read_upgrade_request(conn, acc, reads_left \\ @upgrade_reads)

  defp read_upgrade_request(_conn, acc, 0),
    do: raise("no complete upgrade request after #{@upgrade_reads} reads: #{inspect(acc)}")

  defp read_upgrade_request(conn, acc, reads_left) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(conn, 0, 5_000)
      read_upgrade_request(conn, acc <> data, reads_left - 1)
    end
  end
end
