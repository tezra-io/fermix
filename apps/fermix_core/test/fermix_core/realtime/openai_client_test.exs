defmodule FermixCore.Realtime.OpenAIClientTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.OpenAIClient

  test "builds current WebSocket URL and headers" do
    config = Config.normalize(model: "gpt-realtime-2")

    assert OpenAIClient.url(config) == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2"

    headers = OpenAIClient.headers("sk-test", "safety-id")

    assert {"Authorization", "Bearer sk-test"} in headers
    assert {"OpenAI-Safety-Identifier", "safety-id"} in headers
    refute Enum.any?(headers, fn {key, _value} -> key == "OpenAI-Beta" end)
  end

  test "builds session.update with filtered tools and prompt instructions" do
    config = Config.normalize(voice: "marin")

    event =
      OpenAIClient.session_update_event(config, "system instructions", [
        %{
          type: "function",
          name: "tool_a",
          description: "Tool A",
          parameters: %{"type" => "object"}
        }
      ])

    assert event.type == "session.update"
    assert event.session.type == "realtime"
    assert event.session.model == config.model
    # Realtime GA nests effort under a `reasoning` object (NOT the Chat
    # Completions flat `reasoning_effort`, which the API rejects as unknown).
    assert event.session.reasoning == %{effort: config.reasoning_effort}
    assert event.session.instructions == "system instructions"
    assert event.session.output_modalities == ["audio"]

    assert event.session.audio == %{
             input: %{
               format: %{type: "audio/pcm", rate: 24_000},
               transcription: %{model: "whisper-1"},
               turn_detection: %{
                 type: "server_vad",
                 create_response: true,
                 interrupt_response: true,
                 threshold: 0.6,
                 prefix_padding_ms: 300,
                 silence_duration_ms: 800
               },
               noise_reduction: %{type: "near_field"}
             },
             output: %{format: %{type: "audio/pcm", rate: 24_000}, voice: "marin"}
           }

    assert [%{name: "tool_a"}] = event.session.tools
    refute Map.has_key?(event.session, :input_audio_format)
    refute Map.has_key?(event.session, :max_response_output_tokens)
  end

  # The cap used to ride only on explicit `response.create` messages, so the
  # responses VAD creates on its own — the overwhelming majority of a call —
  # were uncapped. The session-level key is the one the GA Realtime session
  # applies to every response it starts.
  test "session.update carries the output cap so VAD-created responses honour it" do
    config = Config.normalize(max_response_output_tokens: 1_024)

    event = OpenAIClient.session_update_event(config, "ins", [])

    assert event.session.max_output_tokens == 1_024
    # the per-response field stays: an explicit create still states its own cap
    assert OpenAIClient.response_create_event(config).response.max_output_tokens == 1_024
  end

  test "session.update honours custom transcription_model" do
    config = Config.normalize(transcription_model: "gpt-4o-transcribe")

    event = OpenAIClient.session_update_event(config, "ins", [])

    assert event.session.audio.input.transcription == %{model: "gpt-4o-transcribe"}
  end

  test "session.update carries the configured reasoning effort under a reasoning object" do
    event =
      OpenAIClient.session_update_event(Config.normalize(reasoning_effort: "high"), "ins", [])

    assert event.session.reasoning == %{effort: "high"}
    # Guard the exact bug: the flat Chat-Completions key is rejected by Realtime.
    refute Map.has_key?(event.session, :reasoning_effort)
  end

  test "builds audio append, cancel, truncate, response, and function output events" do
    assert OpenAIClient.audio_append_event("pcm") == %{
             type: "input_audio_buffer.append",
             audio: Base.encode64("pcm")
           }

    assert OpenAIClient.response_create_event(Config.normalize(max_response_output_tokens: 1_024)) ==
             %{
               type: "response.create",
               response: %{max_output_tokens: 1_024}
             }

    assert OpenAIClient.cancel_response_event() == %{type: "response.cancel"}

    assert OpenAIClient.truncate_item_event("item-42", 1_750) == %{
             type: "conversation.item.truncate",
             item_id: "item-42",
             content_index: 0,
             audio_end_ms: 1_750
           }

    assert [
             %{
               type: "conversation.item.create",
               item: %{type: "function_call_output", call_id: "call-1", output: "{\"ok\":true}"}
             },
             %{type: "response.create", response: %{max_output_tokens: 4_096}}
           ] =
             OpenAIClient.function_output_events(
               %{call_id: "call-1", output: "{\"ok\":true}"},
               Config.normalize([])
             )
  end

  test "function_output_events emits an input_image item per image, before response.create" do
    events =
      OpenAIClient.function_output_events(
        %{
          call_id: "call-1",
          output: "screenshot text",
          images: [%{type: :image, mime_type: "image/png", data: <<137, 80, 78, 71>>}]
        },
        Config.normalize([])
      )

    assert [
             %{item: %{type: "function_call_output", call_id: "call-1"}},
             %{
               type: "conversation.item.create",
               item: %{
                 type: "message",
                 role: "user",
                 content: [
                   %{type: "input_text", text: notice},
                   %{type: "input_image", image_url: image_url}
                 ]
               }
             },
             %{type: "response.create"}
           ] = events

    assert notice =~ "untrusted"
    assert image_url == "data:image/png;base64," <> Base.encode64(<<137, 80, 78, 71>>)
  end

  # This caption rides EVERY tool image — in an action sequence that is the freshest
  # instruction before each forced `response.create`, so a "describe it" here is a
  # standing order to narrate. The sibling frame caption had the same imperative
  # removed; this copy was missed and outnumbered the prompt's silence rule.
  test "the tool-image caption does not order the model to describe what it sees" do
    [_output, %{item: %{content: [%{text: notice} | _]}}, _create] =
      OpenAIClient.function_output_events(
        %{
          call_id: "call-1",
          output: "screenshot text",
          images: [%{type: :image, mime_type: "image/png", data: <<137, 80, 78, 71>>}]
        },
        Config.normalize([])
      )

    refute notice =~ "describe it"
    assert notice =~ "act on what it shows"
    assert notice =~ "untrusted data"
  end

  test "decodes provider events into internal event tuples" do
    assert {:ok, {:audio_delta, "item-1", "abc"}} =
             OpenAIClient.decode_server_event(%{
               "type" => "response.audio.delta",
               "item_id" => "item-1",
               "delta" => "abc"
             })

    assert {:ok, {:audio_delta, nil, "abc"}} =
             OpenAIClient.decode_server_event(%{
               "type" => "response.audio.delta",
               "delta" => "abc"
             })

    assert {:ok, {:assistant_transcript_delta, "hello"}} =
             OpenAIClient.decode_server_event(%{
               "type" => "response.audio_transcript.delta",
               "delta" => "hello"
             })

    assert {:ok, {:assistant_transcript_done, "hello"}} =
             OpenAIClient.decode_server_event(%{
               "type" => "response.audio_transcript.done",
               "transcript" => "hello"
             })

    assert {:ok, {:user_transcript_done, "question"}} =
             OpenAIClient.decode_server_event(%{
               "type" => "conversation.item.input_audio_transcription.completed",
               "transcript" => "question"
             })

    assert {:ok, {:input_audio_committed, %{"type" => "input_audio_buffer.committed"}}} =
             OpenAIClient.decode_server_event(%{"type" => "input_audio_buffer.committed"})

    assert {:ok, {:session_updated, %{"type" => "session.updated"}}} =
             OpenAIClient.decode_server_event(%{"type" => "session.updated"})

    assert {:ok, {:session_created, %{"type" => "session.created"}}} =
             OpenAIClient.decode_server_event(%{"type" => "session.created"})

    assert {:ok, {:function_call, %{"name" => "echo"}}} =
             OpenAIClient.decode_server_event(%{
               "type" => "response.function_call_arguments.done",
               "name" => "echo"
             })

    assert {:ok, {:response_done, %{"status" => "completed"}}} =
             OpenAIClient.decode_server_event(%{
               "type" => "response.done",
               "response" => %{"status" => "completed"}
             })
  end

  # The session acts only on the socket it currently uses, so every message a
  # socket sends names it. `handle_frame/2` runs inside the socket process, where
  # `self()` is the socket.
  describe "messages to the session name the socket" do
    test "a decoded event carries the socket pid" do
      me = self()

      assert {:ok, _state} =
               OpenAIClient.handle_frame({:text, ~s({"type":"session.created"})}, %{parent: me})

      assert_received {:openai_realtime_event, ^me, {:session_created, _event}}
    end

    test "a frame that is not JSON is an error that carries the socket pid" do
      me = self()

      assert {:ok, _state} = OpenAIClient.handle_frame({:text, "not json"}, %{parent: me})

      assert_received {:openai_realtime_error, ^me, {:decode_failed, _message}}
    end

    test "an event with no type is an error that carries the socket pid" do
      me = self()

      assert {:ok, _state} = OpenAIClient.handle_frame({:text, ~s({"no":"type"})}, %{parent: me})

      assert_received {:openai_realtime_error, ^me, {:invalid_server_event, %{"no" => "type"}}}
    end

    # The socket's EXIT is the one signal that it died. A second notice from
    # `handle_disconnect/2` raced the EXIT of the socket that replaced it.
    test "a disconnect sends the session nothing" do
      status = %{reason: {:remote, :closed}, conn: nil, attempt_number: 1}

      assert {:ok, _state} = OpenAIClient.handle_disconnect(status, %{parent: self()})

      assert Process.info(self(), :messages) == {:messages, []}
    end

    # The session's one liveness signal, over a real WebSockex connection on
    # loopback: the link `start_link/1` makes. An unlinked start would lose every
    # reconnect with the session tests (whose fake sockets link by construction)
    # still green.
    test "a real socket's events name it, and its death reaches the caller only as its EXIT" do
      Process.flag(:trap_exit, true)
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)
      server = Task.async(fn -> serve_one_frame_then_drop(listen) end)

      assert {:ok, socket} =
               OpenAIClient.start_link(
                 url: "ws://127.0.0.1:#{port}/",
                 headers: [],
                 parent: self()
               )

      send(server.pid, :drop)

      assert_receive {:openai_realtime_event, ^socket, {:session_created, _event}}
      assert_receive {:EXIT, ^socket, {:remote, :closed}}
      assert :ok = Task.await(server)
      assert_receive {:EXIT, _task, :normal}
      :ok = :gen_tcp.close(listen)
      assert Process.info(self(), :messages) == {:messages, []}
    end
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

    payload = ~s({"type":"session.created"})
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

  describe "start_options/2" do
    test "verifies the OpenAI peer instead of taking WebSockex's insecure default" do
      config = Config.normalize(model: "gpt-realtime-2")

      assert {:ok, opts} =
               OpenAIClient.start_options(
                 OpenAIClient.url(config),
                 OpenAIClient.headers("sk-test", "safety-id")
               )

      # Without :ssl_options WebSockex connects with verify: :verify_none, and
      # the bearer token in the headers below goes to whoever answered.
      ssl_options = Keyword.fetch!(opts, :ssl_options)

      assert ssl_options[:verify] == :verify_peer
      assert ssl_options[:server_name_indication] == ~c"api.openai.com"

      assert {"Authorization", "Bearer sk-test"} in opts[:extra_headers]
      assert opts[:handshake_timeout] == OpenAIClient.handshake_timeout_ms()
    end

    test "refuses a URL with no host rather than dialing a peer it cannot verify" do
      assert OpenAIClient.start_options("api.openai.com/v1/realtime", []) ==
               {:error, :ws_url_without_host}

      assert OpenAIClient.start_options("wss:///v1/realtime", []) ==
               {:error, :ws_url_without_host}
    end
  end
end
