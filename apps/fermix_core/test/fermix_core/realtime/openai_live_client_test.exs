defmodule FermixCore.Realtime.OpenAILiveClientTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.OpenAILiveClient

  @instructions "# LIVE.md — Live Voice Companion\n\nBackend tools:\n- Web: web_search"

  describe "url/0 and headers/1" do
    test "dials the documented Live sessions endpoint with no query" do
      assert OpenAILiveClient.url() == "wss://api.openai.com/v1/live/sessions"
    end

    test "sends the bearer token and nothing else" do
      assert OpenAILiveClient.headers("sk-test") == [{"Authorization", "Bearer sk-test"}]
    end
  end

  describe "start_options/2" do
    test "verifies the peer against the trust store instead of WebSockex's insecure default" do
      assert {:ok, options} = OpenAILiveClient.start_options(OpenAILiveClient.url(), [])

      assert options[:ssl_options][:verify] == :verify_peer
      assert options[:ssl_options][:server_name_indication] == ~c"api.openai.com"
      assert is_integer(options[:handshake_timeout])
    end

    test "refuses a URL that names no host" do
      assert {:error, :ws_url_without_host} = OpenAILiveClient.start_options("wss:///live", [])
    end
  end

  describe "session_start_event/3" do
    test "carries exactly the keys the Live session accepts" do
      event = OpenAILiveClient.session_start_event(config(), @instructions, event_id: "ev_1")

      assert event == %{
               type: "session.start",
               event_id: "ev_1",
               session: %{
                 model: "gpt-live-1",
                 instructions: @instructions,
                 audio: %{
                   format: %{type: "audio/pcm", rate: 24_000},
                   output: %{voice: "marin"}
                 },
                 delegation: %{type: "client"},
                 store: false
               }
             }
    end

    test "never carries a Realtime-only key" do
      keys =
        config()
        |> OpenAILiveClient.session_start_event(@instructions, [])
        |> payload_keys()

      for key <- ~w(reasoning turn_detection transcription max_output_tokens tools tool_choice
                    output_modalities noise_reduction input) do
        refute key in keys
      end
    end
  end

  describe "append builders" do
    test "audio appends carry base64 PCM and no event id, because they are never acked" do
      assert OpenAILiveClient.audio_append_event(<<1, 2, 3, 4>>) == %{
               type: "session.input_audio.append",
               audio: Base.encode64(<<1, 2, 3, 4>>)
             }
    end

    test "instructions appends carry a present null delegation id" do
      assert {"ev_2", event} =
               OpenAILiveClient.instructions_append_event("ev_2", nil, "Stop speaking now.")

      assert event == %{
               type: "session.instructions.append",
               event_id: "ev_2",
               delegation_id: nil,
               content: "Stop speaking now."
             }

      assert Jason.encode!(event) =~ ~s("delegation_id":null)
    end

    test "thinking and commentary appends name their delegation" do
      assert {"ev_3", thinking} =
               OpenAILiveClient.thinking_append_event("ev_3", "dg_1", "Using read_file")

      assert thinking == %{
               type: "session.thinking.append",
               event_id: "ev_3",
               delegation_id: "dg_1",
               content: "Using read_file"
             }

      assert {"ev_4", commentary} =
               OpenAILiveClient.commentary_append_event("ev_4", "dg_1", "The room is booked.")

      assert commentary == %{
               type: "session.commentary.append",
               event_id: "ev_4",
               delegation_id: "dg_1",
               content: "The room is booked."
             }
    end

    test "mute and close carry their event id" do
      assert OpenAILiveClient.mute_event("ev_5", true) == %{
               type: "session.input_audio.mute",
               event_id: "ev_5"
             }

      assert OpenAILiveClient.mute_event("ev_6", false) == %{
               type: "session.input_audio.unmute",
               event_id: "ev_6"
             }

      assert OpenAILiveClient.close_event("ev_7") == %{
               type: "session.close",
               event_id: "ev_7"
             }
    end

    test "every event id is unique" do
      ids = Enum.map(1..50, fn _index -> OpenAILiveClient.new_event_id() end)

      assert length(Enum.uniq(ids)) == 50
    end
  end

  describe "decode_server_event/1" do
    test "session.started carries the provider id and expiry" do
      assert {:ok, {:session_started, %{id: "sess_1", expires_at: 1_788_000_000}}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "session.started",
                 "session" => %{"id" => "sess_1", "expires_at" => 1_788_000_000}
               })
    end

    test "session.started without an expiry reports none" do
      assert {:ok, {:session_started, %{id: "sess_1", expires_at: nil}}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "session.started",
                 "session" => %{"id" => "sess_1"}
               })
    end

    test "mute acknowledgements decode to a boolean" do
      assert {:ok, {:input_muted, true}} =
               OpenAILiveClient.decode_server_event(%{"type" => "session.input_audio.muted"})

      assert {:ok, {:input_muted, false}} =
               OpenAILiveClient.decode_server_event(%{"type" => "session.input_audio.unmuted"})
    end

    test "append acknowledgements name their kind and echo the client event id" do
      for {type, kind} <- [
            {"session.instructions.appended", :instructions},
            {"session.thinking.appended", :thinking},
            {"session.commentary.appended", :commentary}
          ] do
        assert {:ok, {:append_acked, ^kind, "ev_1"}} =
                 OpenAILiveClient.decode_server_event(%{
                   "type" => type,
                   "client_event_id" => "ev_1",
                   "start_ms" => 10,
                   "end_ms" => 20
                 })
      end
    end

    test "output audio deltas decode with and without timing fields" do
      assert {:ok, {:audio_delta, "AAAA"}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "session.output_audio.delta",
                 "delta" => "AAAA"
               })

      assert {:ok, {:audio_delta, "AAAA"}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "session.output_audio.delta",
                 "delta" => "AAAA",
                 "start_ms" => 100,
                 "end_ms" => 140
               })
    end

    test "transcript deltas name their speaker and keep their timings" do
      assert {:ok, {:transcript_delta, :user, "book ", 1_200, 1_640}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "session.input_transcript.delta",
                 "delta" => "book ",
                 "start_ms" => 1_200,
                 "end_ms" => 1_640
               })

      assert {:ok, {:transcript_delta, :assistant, "on it", 2_000, 2_400}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "session.output_transcript.delta",
                 "delta" => "on it",
                 "start_ms" => 2_000,
                 "end_ms" => 2_400
               })
    end

    test "a client delegation decodes; a foreign target does not" do
      assert {:ok, {:delegation_created, "dg_1", 4_200}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "session.delegation.created",
                 "delegation" => %{"id" => "dg_1", "target" => "client"},
                 "offset_ms" => 4_200
               })

      assert {:ok, {:unhandled, "session.delegation.created", _event}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "session.delegation.created",
                 "delegation" => %{"id" => "dg_1", "target" => "server"},
                 "offset_ms" => 4_200
               })
    end

    test "usage updates yield the cumulative seconds" do
      assert {:ok, {:usage_updated, 64.2}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "session.usage.updated",
                 "usage" => %{"seconds" => 64.2},
                 "context_window" => %{"usage_ratio" => 0.1}
               })
    end

    test "session.closed yields the reason and the terminal seconds" do
      assert {:ok, {:session_closed, "close_requested", 120.5}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "session.closed",
                 "reason" => "close_requested",
                 "usage" => %{"seconds" => 120.5}
               })

      assert {:ok, {:session_closed, "expired", nil}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "session.closed",
                 "reason" => "expired"
               })
    end

    test "an error is decoded as data, not as a failure" do
      assert {:ok, {:error, %{"type" => "invalid_request_error", "message" => "nope"}}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "error",
                 "error" => %{"type" => "invalid_request_error", "message" => "nope"}
               })
    end

    test "info lines decode to a code and a message" do
      assert {:ok, {:info, "audio_truncated", "the buffer was trimmed"}} =
               OpenAILiveClient.decode_server_event(%{
                 "type" => "info",
                 "code" => "audio_truncated",
                 "message" => "the buffer was trimmed"
               })
    end

    test "tolerated event families decode as unhandled instead of failing" do
      for type <- [
            "response.event",
            "transport.ping",
            "transport.pong",
            "session.input_audio.append",
            "session.updated"
          ] do
        assert {:ok, decoded} = OpenAILiveClient.decode_server_event(%{"type" => type})
        assert elem(decoded, 0) in [:unhandled, :session_updated]
      end
    end

    test "a frame with no type is a decode error" do
      assert {:error, {:invalid_server_event, %{}}} = OpenAILiveClient.decode_server_event(%{})
    end
  end

  defp config do
    Config.normalize(enabled: true, engine: "openai_live", model: "gpt-live-1", voice: "marin")
  end

  # Every key name in the payload, at every depth — the vocabulary the provider
  # actually reads, as opposed to the prose inside `instructions`.
  defp payload_keys(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> [to_string(key) | payload_keys(value)] end)
  end

  defp payload_keys(_value), do: []
end
