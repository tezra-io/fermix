defmodule FermixCore.Providers.OpenAI.ChatCompletionsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Providers.OpenAI.ChatCompletions

  defp capability do
    Capability.new(%{
      name: "echo",
      description: "Echo input back",
      parameters: %{type: "object", properties: %{text: %{type: "string"}}, required: ["text"]},
      kind: :builtin,
      executor: {Kernel, :inspect, []}
    })
  end

  defp text_response_body do
    %{
      "model" => "gpt-5.4-mini",
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => "Hi there"},
          "model" => "gpt-5.4-mini"
        }
      ],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
    }
  end

  defp tool_call_response_body do
    %{
      "model" => "gpt-5.4-mini",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_abc",
                "type" => "function",
                "function" => %{
                  "name" => "echo",
                  "arguments" => Jason.encode!(%{"text" => "hello"})
                }
              }
            ]
          },
          "model" => "gpt-5.4-mini"
        }
      ],
      "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 4, "total_tokens" => 11}
    }
  end

  describe "to_provider_tools/1" do
    test "wraps each capability in {type: function, function: {...}}" do
      [tool] = ChatCompletions.to_provider_tools([capability()])

      assert tool.type == "function"
      assert tool.function.name == "echo"
      assert tool.function.description == "Echo input back"
      assert is_map(tool.function.parameters)
    end

    test "returns [] when given []" do
      assert ChatCompletions.to_provider_tools([]) == []
    end
  end

  describe "parse_response/1" do
    test "builds a normalized turn from a text-only response" do
      turn = ChatCompletions.parse_response(text_response_body())

      assert turn.content == "Hi there"
      assert turn.tool_calls == []
      assert turn.usage.prompt_tokens == 5
      assert turn.usage.completion_tokens == 3
      assert turn.usage.total_tokens == 8
      assert turn.model == "gpt-5.4-mini"
    end

    test "normalizes tool calls into atom-keyed maps" do
      turn = ChatCompletions.parse_response(tool_call_response_body())

      assert [tool_call] = turn.tool_calls
      assert tool_call.id == "call_abc"
      assert tool_call.call_id == "call_abc"
      assert tool_call.name == "echo"
      assert is_binary(tool_call.arguments)
    end
  end

  describe "parse_tool_calls/1" do
    test "extracts and normalizes tool_calls when present" do
      [tool_call] = ChatCompletions.parse_tool_calls(tool_call_response_body())
      assert tool_call.name == "echo"
      assert tool_call.call_id == "call_abc"
    end

    test "returns [] for text-only responses" do
      assert ChatCompletions.parse_tool_calls(text_response_body()) == []
    end
  end

  describe "chat/3 — request shape and response handling" do
    test "posts the standard chat completions body and parses the response" do
      test_pid = self()
      handler_id = "test-chat-completions-tool-schema-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :tool_schema],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "memory_candidates",
          strict: true,
          schema: %{type: "object", required: ["candidates"]}
        }
      }

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "gpt-5.4-mini"
        assert decoded["temperature"] == 0.4
        assert is_list(decoded["messages"])
        assert is_list(decoded["tools"])
        assert hd(decoded["tools"])["type"] == "function"
        assert hd(decoded["tools"])["function"]["name"] == "echo"
        assert decoded["response_format"]["json_schema"]["strict"] == true

        Req.Test.json(conn, text_response_body())
      end)

      messages = [%{role: "user", content: "Hi"}]

      {:ok, turn} =
        ChatCompletions.chat(messages, [capability()],
          api_key: "sk-test",
          model: "gpt-5.4-mini",
          temperature: 0.4,
          response_format: response_format,
          base_url: "https://api.openai.com/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert turn.content == "Hi there"
      assert turn.provider_state.messages == messages
      assert turn.provider_state.assistant.role == "assistant"
      assert turn.provider_state.capabilities == [capability()]

      assert_receive {:telemetry, [:fermix, :provider, :tool_schema], measurements,
                      %{adapter: :chat_completions} = metadata}

      assert measurements.duration_us >= 0
      assert measurements.tools_count == 1
      refute Map.has_key?(measurements, :tools_bytes)
      assert measurements.capabilities_count == 1
      assert metadata.adapter == :chat_completions
    end

    test "returns an auth error when api_key is missing" do
      assert {:error, {:provider_error, %{provider: :openai, kind: :auth, message: message}}} =
               ChatCompletions.chat([], [], model: "gpt-5.4-mini")

      assert message =~ "requires :api_key"
    end

    test "returns structured provider errors on a non-200 response" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          401,
          Jason.encode!(%{error: %{code: "invalid_api_key", message: "bad key"}})
        )
      end)

      {:error, {:provider_error, error}} =
        ChatCompletions.chat([%{role: "user", content: "x"}], [],
          api_key: "sk-test",
          model: "gpt-5.4-mini",
          base_url: "https://api.openai.com/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert error.provider == :openai
      assert error.adapter == :chat_completions
      assert error.status == 401
      assert error.kind == :auth
      assert error.code == "invalid_api_key"
      assert error.message == "bad key"
    end

    test "error telemetry includes provider error details" do
      test_pid = self()
      telemetry_id = "chat-completions-provider-error-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        telemetry_id,
        [:fermix, :provider, :call],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(telemetry_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          429,
          Jason.encode!(%{error: %{code: "insufficient_quota", message: "quota exhausted"}})
        )
      end)

      {:error, {:provider_error, _error}} =
        ChatCompletions.chat([%{role: "user", content: "x"}], [],
          api_key: "sk-test",
          model: "gpt-5.4-mini",
          base_url: "https://api.openai.com/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert_receive {:telemetry, [:fermix, :provider, :call], measurements,
                      %{adapter: :chat_completions, error_status: 429} = metadata}

      assert measurements.duration_ms >= 0
      assert metadata.status == :error
      assert metadata.error_kind == :quota
      assert metadata.error_code == "insufficient_quota"
      assert metadata.error == "quota exhausted"
    end
  end

  describe "continue/3" do
    test "appends assistant + tool result messages and re-posts" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        roles = Enum.map(decoded["messages"], & &1["role"])
        assert "tool" in roles

        Req.Test.json(conn, text_response_body())
      end)

      provider_state = %{
        messages: [%{role: "user", content: "Hi"}],
        assistant: %{role: "assistant", content: "", tool_calls: []},
        capabilities: [capability()]
      }

      tool_results = [%{call_id: "call_abc", output: "echoed"}]

      {:ok, turn} =
        ChatCompletions.continue(provider_state, tool_results,
          api_key: "sk-test",
          model: "gpt-5.4-mini",
          base_url: "https://api.openai.com/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert turn.content == "Hi there"
    end
  end

  describe "supports_streaming?/0" do
    test "returns false" do
      refute ChatCompletions.supports_streaming?()
    end
  end
end
