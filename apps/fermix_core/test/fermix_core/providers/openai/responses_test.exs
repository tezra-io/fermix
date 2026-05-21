defmodule FermixCore.Providers.OpenAI.ResponsesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Providers.OpenAI.Responses

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
      "output" => [
        %{
          "type" => "message",
          "id" => "msg_1",
          "content" => [%{"type" => "output_text", "text" => "Hello user"}]
        }
      ],
      "usage" => %{"input_tokens" => 9, "output_tokens" => 3}
    }
  end

  defp function_call_response_body do
    %{
      "model" => "gpt-5.4-mini",
      "output" => [
        %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_xyz",
          "name" => "echo",
          "arguments" => Jason.encode!(%{"text" => "yo"})
        }
      ],
      "usage" => %{"input_tokens" => 6, "output_tokens" => 4}
    }
  end

  defp missing_call_id_body do
    %{
      "model" => "gpt-5.4-mini",
      "output" => [
        %{
          "type" => "function_call",
          "id" => "fc_only",
          "name" => "echo",
          "arguments" => Jason.encode!(%{"text" => "yo"})
        }
      ],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }
  end

  defp reasoning_response_body do
    %{
      "model" => "gpt-5.4-mini",
      "output" => [
        %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "..."},
        %{
          "type" => "message",
          "id" => "msg_2",
          "content" => [%{"type" => "output_text", "text" => "thought it through"}]
        }
      ],
      "usage" => %{"input_tokens" => 4, "output_tokens" => 12}
    }
  end

  describe "to_provider_tools/1" do
    test "produces flat function shape with strict: false" do
      [tool] = Responses.to_provider_tools([capability()])

      assert tool.type == "function"
      assert tool.name == "echo"
      assert tool.description == "Echo input back"
      assert is_map(tool.parameters)
      assert tool.strict == false
    end

    test "returns [] for []" do
      assert Responses.to_provider_tools([]) == []
    end
  end

  describe "parse_response/1" do
    test "extracts text content from a message item" do
      turn = Responses.parse_response(text_response_body())

      assert turn.content == "Hello user"
      assert turn.tool_calls == []
      assert turn.usage.prompt_tokens == 9
      assert turn.usage.completion_tokens == 3
      assert turn.usage.total_tokens == 12
    end

    test "normalizes function_call items into atom-keyed maps" do
      turn = Responses.parse_response(function_call_response_body())

      assert [tc] = turn.tool_calls
      assert tc.id == "fc_1"
      assert tc.call_id == "call_xyz"
      assert tc.name == "echo"
      assert is_binary(tc.arguments)
    end

    test "falls back to a deterministic call_id when API omits it" do
      turn = Responses.parse_response(missing_call_id_body())

      assert [tc] = turn.tool_calls
      assert String.starts_with?(tc.call_id, "call_")
      assert byte_size(tc.call_id) == String.length("call_") + 12
    end

    test "preserves reasoning items in provider_state.output_items" do
      turn = Responses.parse_response(reasoning_response_body())

      types = Enum.map(turn.provider_state.output_items, & &1["type"])
      assert "reasoning" in types
      assert "message" in types
    end
  end

  describe "chat/3 — request shape and response handling" do
    test "emits provider telemetry with request shape" do
      test_pid = self()
      handler_id = "test-responses-request-shape-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [[:fermix, :provider, :call], [:fermix, :provider, :tool_schema]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} =
               Responses.chat(
                 [
                   %{role: "system", content: "You are helpful"},
                   %{role: "user", content: "Hi"}
                 ],
                 [capability()],
                 api_key: "sk-test",
                 model: "gpt-5.4-mini",
                 base_url: "https://api.openai.com/v1",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      assert_receive {:telemetry, [:fermix, :provider, :call], measurements,
                      %{adapter: :responses} = metadata}
      assert measurements.duration_ms >= 0
      assert metadata.input_items == 1
      assert metadata.input_bytes > 0
      assert metadata.instructions_bytes == byte_size("You are helpful")
      assert metadata.tools_count == 1
      assert metadata.tools_bytes > 0
      assert metadata.capabilities_count == 1

      assert_receive {:telemetry, [:fermix, :provider, :tool_schema], tool_measurements,
                      %{adapter: :responses_shared} = tool_metadata}

      assert tool_measurements.duration_us >= 0
      assert tool_measurements.tools_count == 1
      refute Map.has_key?(tool_measurements, :tools_bytes)
      assert tool_metadata.adapter == :responses_shared
    end

    test "posts item-list input with separate instructions and parses the response" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "gpt-5.4-mini"
        assert decoded["instructions"] == "You are helpful"
        assert decoded["store"] == false
        assert is_list(decoded["input"])
        assert hd(decoded["input"])["role"] == "user"

        Req.Test.json(conn, text_response_body())
      end)

      messages = [
        %{role: "system", content: "You are helpful"},
        %{role: "user", content: "Hi"}
      ]

      {:ok, turn} =
        Responses.chat(messages, [capability()],
          api_key: "sk-test",
          model: "gpt-5.4-mini",
          base_url: "https://api.openai.com/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert turn.content == "Hello user"
      assert turn.provider_state.tools != []
      assert turn.provider_state.capabilities == [capability()]
    end

    test "raises when api_key is missing" do
      assert_raise ArgumentError, ~r/requires :api_key/, fn ->
        Responses.chat([%{role: "user", content: "x"}], [], model: "gpt-5.4-mini")
      end
    end

    test "returns {:error, _} on a non-200 response" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, Jason.encode!(%{error: "boom"}))
      end)

      {:error, message} =
        Responses.chat([%{role: "user", content: "x"}], [],
          api_key: "sk-test",
          model: "gpt-5.4-mini",
          base_url: "https://api.openai.com/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert message == "OpenAI Responses API error: 500"
    end

    test "provider telemetry includes the agent when supplied" do
      telemetry_id = "responses-provider-agent-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        telemetry_id,
        [:fermix, :provider, :call],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(telemetry_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, text_response_body())
      end)

      {:ok, _turn} =
        Responses.chat([%{role: "user", content: "x"}], [],
          agent: "main",
          api_key: "sk-test",
          model: "gpt-5.4-mini",
          base_url: "https://api.openai.com/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert_receive {:telemetry, [:fermix, :provider, :call], _measurements, metadata}
      assert metadata.agent == "main"
    end
  end

  describe "continue/3" do
    test "next input contains prior input + output items + function_call_outputs" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        types = Enum.map(decoded["input"], &(&1["type"] || &1["role"]))
        assert "function_call" in types
        assert "function_call_output" in types
        assert "user" in types

        Req.Test.json(conn, text_response_body())
      end)

      provider_state = %{
        input: [%{role: "user", content: [%{type: "input_text", text: "Hi"}]}],
        output_items: [
          %{
            "type" => "function_call",
            "id" => "fc_1",
            "call_id" => "call_xyz",
            "name" => "echo",
            "arguments" => "{}"
          }
        ],
        tools: [],
        capabilities: [capability()]
      }

      {:ok, turn} =
        Responses.continue(provider_state, [%{call_id: "call_xyz", output: "echoed"}],
          api_key: "sk-test",
          model: "gpt-5.4-mini",
          base_url: "https://api.openai.com/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert turn.content == "Hello user"
    end
  end

  describe "supports_streaming?/0" do
    test "returns false" do
      refute Responses.supports_streaming?()
    end
  end

  describe "chat/3 — reasoning effort body shape" do
    test "omits the reasoning field when :reasoning_effort is nil" do
      decoded = capture_body(reasoning_effort: nil)
      refute Map.has_key?(decoded, "reasoning")
    end

    test "omits the reasoning field when :reasoning_effort is :none" do
      decoded = capture_body(reasoning_effort: :none)
      refute Map.has_key?(decoded, "reasoning")
    end

    test "sends reasoning: %{effort: <level>} for each valid non-:none level" do
      for level <- [:minimal, :low, :medium, :high, :xhigh] do
        decoded = capture_body(reasoning_effort: level)
        assert decoded["reasoning"] == %{"effort" => Atom.to_string(level)}
      end
    end

    test "sends strict text.format schema when supplied" do
      decoded =
        capture_body(
          text_format: %{
            type: "json_schema",
            name: "memory_candidates",
            strict: true,
            schema: %{type: "object", required: ["candidates"]}
          }
        )

      assert decoded["text"]["format"]["type"] == "json_schema"
      assert decoded["text"]["format"]["strict"] == true
      assert decoded["text"]["format"]["schema"]["required"] == ["candidates"]
    end

    test "raises ArgumentError for an invalid effort level" do
      assert_raise ArgumentError, ~r/invalid reasoning_effort: :weird/, fn ->
        Responses.chat([%{role: "user", content: "x"}], [],
          api_key: "sk-test",
          model: "gpt-5.4-mini",
          reasoning_effort: :weird,
          base_url: "https://api.openai.com/v1"
        )
      end
    end
  end

  defp capture_body(opts) do
    test_id = :"responses_capture_#{System.unique_integer([:positive])}"
    parent = self()

    Req.Test.stub(test_id, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:captured_body, Jason.decode!(body)})
      Req.Test.json(conn, %{"model" => "gpt-5", "output" => [], "usage" => %{}})
    end)

    {:ok, _turn} =
      Responses.chat(
        [%{role: "user", content: "Hi"}],
        [],
        Keyword.merge(
          [
            api_key: "sk-test",
            model: "gpt-5",
            base_url: "https://api.openai.com/v1",
            req_options: [plug: {Req.Test, test_id}]
          ],
          opts
        )
      )

    receive do
      {:captured_body, decoded} -> decoded
    after
      500 -> flunk("no body captured")
    end
  end
end
