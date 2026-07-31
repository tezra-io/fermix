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
    test "a user image_parts message becomes a multimodal content array" do
      png = <<137, 80, 78, 71>>

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert [%{"role" => "user", "content" => [text_part, image_part]}] = decoded["messages"]
        assert text_part == %{"type" => "text", "text" => "what is this?"}
        assert image_part["type"] == "image_url"
        assert image_part["image_url"]["url"] == "data:image/png;base64," <> Base.encode64(png)

        Req.Test.json(conn, text_response_body())
      end)

      messages = [
        %{
          role: "user",
          content: "what is this?",
          image_parts: [%{type: :image, mime_type: "image/png", data: png}]
        }
      ]

      assert {:ok, _turn} =
               ChatCompletions.chat(messages, [],
                 api_key: "sk-test",
                 provider: :openai,
                 model: "gpt-5.4-mini",
                 base_url: "https://api.openai.com/v1",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "posts the standard chat completions body and parses the response" do
      test_pid = self()
      handler_id = "test-chat-completions-tool-schema-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :tool_schema],
        fn event, measurements, metadata, _config ->
          if self() == test_pid do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
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
          provider: :openai,
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

    test "sends reasoning_effort on the wire and reports it on the call telemetry" do
      handler_id = "cc-effort-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid do
            send(test_pid, {:telemetry_call, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["reasoning_effort"] == "high"
        Req.Test.json(conn, text_response_body())
      end)

      {:ok, _turn} =
        ChatCompletions.chat([%{role: "user", content: "hi"}], [],
          api_key: "sk-test",
          provider: :openai,
          model: "o4-custom",
          base_url: "https://api.openai.com/v1",
          reasoning_effort: :high,
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert_receive {:telemetry_call, %{provider: :openai, reasoning_effort: :high}}
    end

    test "omits reasoning_effort from the body and telemetry when unset (effort-less providers)" do
      handler_id = "cc-effort-absent-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid do
            send(test_pid, {:telemetry_call, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        refute Map.has_key?(Jason.decode!(body), "reasoning_effort")
        Req.Test.json(conn, text_response_body())
      end)

      {:ok, _turn} =
        ChatCompletions.chat([%{role: "user", content: "hi"}], [],
          api_key: "sk-or-test",
          provider: :openrouter,
          model: "anthropic/claude-sonnet-4.6",
          base_url: "https://openrouter.test/api/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert_receive {:telemetry_call, %{provider: :openrouter, reasoning_effort: nil}}
    end

    test "returns an auth error when api_key is missing" do
      assert {:error, {:provider_error, %{provider: :openai, kind: :auth, message: message}}} =
               ChatCompletions.chat([], [], model: "gpt-5.4-mini", provider: :openai)

      assert message =~ "requires :api_key"
    end

    test "keyless auth (:none) sends no authorization header and needs no key" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:auth_header, Plug.Conn.get_req_header(conn, "authorization")})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "local ok"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        })
      end)

      assert {:ok, turn} =
               ChatCompletions.chat(
                 [%{role: "user", content: "hi"}],
                 [],
                 model: "qwen3:32b",
                 provider: :ollama,
                 auth: :none,
                 base_url: "http://localhost:11434/v1",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      assert turn.content == "local ok"
      assert_receive {:auth_header, []}
    end

    test "sends OpenRouter attribution headers only for :openrouter" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(
          test_pid,
          {:headers, Plug.Conn.get_req_header(conn, "http-referer"),
           Plug.Conn.get_req_header(conn, "x-title")}
        )

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "ok"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        })
      end)

      base_opts = [
        model: "anthropic/claude-sonnet-4.6",
        api_key: "sk-or-test",
        base_url: "https://openrouter.test/api/v1",
        req_options: [plug: {Req.Test, __MODULE__}]
      ]

      {:ok, _turn} =
        ChatCompletions.chat(
          [%{role: "user", content: "hi"}],
          [],
          Keyword.put(base_opts, :provider, :openrouter)
        )

      assert_receive {:headers, ["https://fermix.sh"], ["Fermix"]}

      {:ok, _turn} =
        ChatCompletions.chat(
          [%{role: "user", content: "hi"}],
          [],
          Keyword.put(base_opts, :provider, :openai)
        )

      assert_receive {:headers, [], []}
    end

    # M12 §2.3-5: the adapter serves several providers; attribution must
    # come from the resolver, never default to :openai.
    test "raises when the :provider opt is missing" do
      assert_raise ArgumentError, ~r/requires a :provider atom/, fn ->
        ChatCompletions.chat([], [], model: "gpt-5.4-mini", api_key: "sk-test")
      end
    end

    test "attributes errors and telemetry to the resolver-supplied provider" do
      handler_id = "cc-provider-attribution-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid do
            send(test_pid, {:telemetry_call, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 429, Jason.encode!(%{error: %{message: "slow down"}}))
      end)

      assert {:error, {:provider_error, %{provider: :openrouter, kind: :rate_limit}}} =
               ChatCompletions.chat(
                 [%{role: "user", content: "hi"}],
                 [],
                 model: "anthropic/claude-sonnet-4.6",
                 api_key: "sk-or-test",
                 provider: :openrouter,
                 base_url: "https://openrouter.test/api/v1",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      # Telemetry handlers are global: filter on provider so concurrently
      # running async tests' events don't cross-match (playbook note 30).
      assert_receive {:telemetry_call, %{provider: :openrouter} = metadata}
      assert metadata.adapter == :chat_completions
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
          provider: :openai,
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
          if self() == test_pid do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
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
          provider: :openai,
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

  describe "continue/3 screenshot retention" do
    @screenshot_label "Screen state returned by the preceding tool call:"
    @screenshot_elided "[earlier screen state omitted to bound context]"

    test "keeps only the most recent N screenshots; older image bytes are elided" do
      test_pid = self()
      png = <<137, 80, 78, 71>>

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_messages, Jason.decode!(body)["messages"]})
        Req.Test.json(conn, text_response_body())
      end)

      # Two screenshot follow-up turns already in history (older), plus a fresh one
      # from this turn's tool result → three total; cap of 1 keeps only the newest.
      old_shot = %{role: "user", content: @screenshot_label, image_parts: [img_part(png, "old")]}

      provider_state = %{
        messages: [%{role: "user", content: "go"}, old_shot, old_shot],
        assistant: %{role: "assistant", content: "", tool_calls: []},
        capabilities: [capability()]
      }

      tool_results = [%{call_id: "c1", output: "captured", images: [img_part(png, "new")]}]

      {:ok, _turn} =
        ChatCompletions.continue(provider_state, tool_results,
          api_key: "sk-test",
          provider: :openai,
          model: "gpt-5.4-mini",
          base_url: "https://api.openai.com/v1",
          max_retained_screenshots: 1,
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert_received {:request_messages, messages}

      image_parts =
        messages
        |> Enum.flat_map(fn m -> List.wrap(m["content"]) end)
        |> Enum.filter(&(is_map(&1) and &1["type"] == "image_url"))

      # exactly one screenshot keeps its bytes (the newest), the two older are elided
      assert length(image_parts) == 1
      assert Enum.count(messages, &(&1["content"] == @screenshot_elided)) == 2
    end

    test "an inbound user image is never elided by retention" do
      test_pid = self()
      png = <<137, 80, 78, 71>>

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_messages, Jason.decode!(body)["messages"]})
        Req.Test.json(conn, text_response_body())
      end)

      # A real user image (no screenshot label) plus an older screenshot carrier.
      user_image = %{role: "user", content: "look", image_parts: [img_part(png, "user")]}
      old_shot = %{role: "user", content: @screenshot_label, image_parts: [img_part(png, "old")]}

      provider_state = %{
        messages: [user_image, old_shot],
        assistant: %{role: "assistant", content: "", tool_calls: []},
        capabilities: [capability()]
      }

      tool_results = [%{call_id: "c1", output: "captured", images: [img_part(png, "new")]}]

      {:ok, _turn} =
        ChatCompletions.continue(provider_state, tool_results,
          api_key: "sk-test",
          provider: :openai,
          model: "gpt-5.4-mini",
          base_url: "https://api.openai.com/v1",
          max_retained_screenshots: 1,
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert_received {:request_messages, messages}

      # The user's own image survives even though it predates the kept screenshot.
      user_msg = Enum.find(messages, &(&1["content"] != nil and is_list(&1["content"])))

      assert Enum.any?(
               List.wrap(user_msg["content"]),
               &(is_map(&1) and &1["type"] == "image_url")
             )
    end

    defp img_part(data, _tag), do: %{type: :image, mime_type: "image/png", data: data}
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
          provider: :openai,
          model: "gpt-5.4-mini",
          base_url: "https://api.openai.com/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert turn.content == "Hi there"
    end

    # Mistral's strict validator 422s on an assistant message that carries
    # empty-string `content` alongside `tool_calls`; the cross-ecosystem fix
    # (langchain #21196, litellm #13355, vllm #38738) is to omit the `content`
    # key entirely in that case. OpenAI/OpenRouter/Ollama tolerate the
    # omission, so one wire shape stays valid on every ChatCompletions provider.
    test "omits content from assistant messages carrying tool_calls" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assistant = Enum.find(decoded["messages"], &(&1["role"] == "assistant"))
        send(test_pid, {:assistant_message, assistant})

        Req.Test.json(conn, text_response_body())
      end)

      provider_state = %{
        messages: [%{role: "user", content: "Hi"}],
        assistant: %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{
              "id" => "abc123def",
              "type" => "function",
              "function" => %{"name" => "echo", "arguments" => "{}"}
            }
          ]
        },
        capabilities: [capability()]
      }

      tool_results = [%{call_id: "abc123def", output: "echoed"}]

      {:ok, _turn} =
        ChatCompletions.continue(provider_state, tool_results,
          api_key: "key",
          provider: :mistral,
          model: "mistral-large-latest",
          base_url: "https://api.mistral.ai/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert_receive {:assistant_message, assistant}
      refute Map.has_key?(assistant, "content")
      assert [%{"id" => "abc123def"}] = assistant["tool_calls"]
    end

    test "an image-bearing tool result emits a text tool message then a subsequent user image turn" do
      png = <<137, 80, 78, 71>>
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})
        Req.Test.json(conn, text_response_body())
      end)

      provider_state = %{
        messages: [%{role: "user", content: "Hi"}],
        assistant: %{role: "assistant", content: "", tool_calls: []},
        capabilities: [capability()]
      }

      tool_results = [
        %{
          call_id: "call_shot",
          output: "captured",
          images: [%{type: :image, mime_type: "image/png", data: png}]
        }
      ]

      {:ok, _turn} =
        ChatCompletions.continue(provider_state, tool_results,
          api_key: "sk-test",
          provider: :openai,
          model: "gpt-5.4-mini",
          base_url: "https://api.openai.com/v1",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert_receive {:body, decoded}
      messages = decoded["messages"]

      # The tool message keeps the call/result pairing; the screenshot rides a
      # SUBSEQUENT user turn (a `tool` message is text-only on this surface).
      assert Enum.map(messages, & &1["role"]) == ["user", "assistant", "tool", "user"]

      tool_msg = Enum.find(messages, &(&1["role"] == "tool"))
      assert tool_msg["tool_call_id"] == "call_shot"
      assert tool_msg["content"] == "captured"

      image_user = List.last(messages)
      assert [text_part, image_part] = image_user["content"]

      assert text_part == %{
               "type" => "text",
               "text" => "Screen state returned by the preceding tool call:"
             }

      assert image_part["type"] == "image_url"
      assert image_part["image_url"]["url"] == "data:image/png;base64," <> Base.encode64(png)
    end
  end

  describe "supports_streaming?/0" do
    test "returns false" do
      refute ChatCompletions.supports_streaming?()
    end
  end
end
