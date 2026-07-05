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

  test "session.update honours custom transcription_model" do
    config = Config.normalize(transcription_model: "gpt-4o-transcribe")

    event = OpenAIClient.session_update_event(config, "ins", [])

    assert event.session.audio.input.transcription == %{model: "gpt-4o-transcribe"}
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
end
