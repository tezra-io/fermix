defmodule FermixCore.Providers.Anthropic.MessagesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Providers.Anthropic.Messages

  defp capability do
    Capability.new(%{
      name: "shell",
      description: "Run a shell command.",
      parameters: %{
        "type" => "object",
        "properties" => %{"command" => %{"type" => "string"}},
        "required" => ["command"]
      },
      kind: :builtin,
      policy_class: :exec,
      executor: {Mod, :run, []}
    })
  end

  defp text_response_body do
    %{
      "id" => "msg_01",
      "model" => "claude-sonnet-4-6",
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => "Hello there"}],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
  end

  defp tool_use_response_body do
    %{
      "id" => "msg_02",
      "model" => "claude-sonnet-4-6",
      "stop_reason" => "tool_use",
      "content" => [
        %{"type" => "text", "text" => "Running it."},
        %{
          "type" => "tool_use",
          "id" => "toolu_01",
          "name" => "shell",
          "input" => %{"command" => "ls"}
        }
      ],
      "usage" => %{"input_tokens" => 20, "output_tokens" => 9}
    }
  end

  defp chat_opts(extra \\ []) do
    Keyword.merge(
      [
        api_key: "sk-ant-test",
        model: "claude-sonnet-4-6",
        base_url: "https://api.anthropic.com/v1",
        req_options: [plug: {Req.Test, __MODULE__}]
      ],
      extra
    )
  end

  describe "to_provider_tools/1" do
    test "returns [] for empty capability list" do
      assert Messages.to_provider_tools([]) == []
    end

    test "translates capabilities to Anthropic input_schema shape, no function wrapper" do
      capabilities = [
        capability(),
        Capability.new(%{
          name: "file_read",
          description: "Read a file.",
          parameters: %{"type" => "object", "properties" => %{}},
          kind: :builtin,
          policy_class: :read_only,
          executor: {Mod, :read, []}
        })
      ]

      assert Messages.to_provider_tools(capabilities) == [
               %{
                 name: "shell",
                 description: "Run a shell command.",
                 input_schema: %{
                   "type" => "object",
                   "properties" => %{"command" => %{"type" => "string"}},
                   "required" => ["command"]
                 }
               },
               %{
                 name: "file_read",
                 description: "Read a file.",
                 input_schema: %{"type" => "object", "properties" => %{}}
               }
             ]
    end
  end

  describe "parse_tool_calls/1" do
    test "extracts tool_use blocks with id, name, input" do
      body = %{
        "content" => [
          %{"type" => "text", "text" => "Let me look that up."},
          %{
            "type" => "tool_use",
            "id" => "toolu_01ABC",
            "name" => "shell",
            "input" => %{"command" => "ls -1"}
          },
          %{
            "type" => "tool_use",
            "id" => "toolu_02DEF",
            "name" => "file_read",
            "input" => %{"path" => "/tmp/x"}
          }
        ]
      }

      assert Messages.parse_tool_calls(body) == [
               %{
                 id: "toolu_01ABC",
                 call_id: "toolu_01ABC",
                 name: "shell",
                 arguments: %{"command" => "ls -1"}
               },
               %{
                 id: "toolu_02DEF",
                 call_id: "toolu_02DEF",
                 name: "file_read",
                 arguments: %{"path" => "/tmp/x"}
               }
             ]
    end

    test "returns [] when content has only text blocks" do
      assert Messages.parse_tool_calls(%{"content" => [%{"type" => "text", "text" => "hi"}]}) ==
               []
    end

    test "returns [] for malformed body" do
      assert Messages.parse_tool_calls(%{}) == []
      assert Messages.parse_tool_calls(nil) == []
    end
  end

  describe "parse_response/1" do
    test "joins text blocks, extracts tool calls, captures usage and stop_reason" do
      body = %{
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "tool_use",
        "content" => [
          %{"type" => "text", "text" => "Calling tools."},
          %{
            "type" => "tool_use",
            "id" => "toolu_01",
            "name" => "shell",
            "input" => %{"command" => "uname"}
          }
        ],
        "usage" => %{"input_tokens" => 12, "output_tokens" => 7}
      }

      turn = Messages.parse_response(body)

      assert turn.content == "Calling tools."
      assert turn.model == "claude-sonnet-4-6"
      assert turn.usage == %{prompt_tokens: 12, completion_tokens: 7, total_tokens: 19}
      assert turn.provider_state.stop_reason == "tool_use"

      assert turn.tool_calls == [
               %{
                 id: "toolu_01",
                 call_id: "toolu_01",
                 name: "shell",
                 arguments: %{"command" => "uname"}
               }
             ]
    end

    test "folds cache creation/read tokens into prompt tokens" do
      body = %{
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => "cached"}],
        "usage" => %{
          "input_tokens" => 3,
          "output_tokens" => 2,
          "cache_creation_input_tokens" => 100,
          "cache_read_input_tokens" => 40
        }
      }

      turn = Messages.parse_response(body)

      assert turn.usage == %{prompt_tokens: 143, completion_tokens: 2, total_tokens: 145}
    end

    test "surfaces refusal text as terminal content" do
      body = %{
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "refusal",
        "content" => [%{"type" => "text", "text" => "I can't help with that."}],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
      }

      turn = Messages.parse_response(body)

      assert turn.content == "I can't help with that."
      assert turn.tool_calls == []
      assert turn.provider_state.stop_reason == "refusal"
    end

    test "treats empty content with end_turn as a valid empty reply" do
      body = %{
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "end_turn",
        "content" => [],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
      }

      turn = Messages.parse_response(body)

      assert turn.content == ""
      assert turn.tool_calls == []
    end

    test "parses unknown stop reasons without crashing" do
      body = %{
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "pause_turn",
        "content" => [%{"type" => "text", "text" => "partial"}],
        "usage" => %{"input_tokens" => 2, "output_tokens" => 1}
      }

      turn = Messages.parse_response(body)

      assert turn.content == "partial"
      assert turn.provider_state.stop_reason == "pause_turn"
    end
  end

  describe "chat/3 — request shape" do
    test "a user image_parts message adds a base64 image block after the text block" do
      png = <<137, 80, 78, 71>>

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert [%{"role" => "user", "content" => [text_block, image_block | _]}] =
                 decoded["messages"]

        assert text_block["type"] == "text"
        assert text_block["text"] == "what is this?"
        assert image_block["type"] == "image"
        assert image_block["source"]["type"] == "base64"
        assert image_block["source"]["media_type"] == "image/png"
        assert image_block["source"]["data"] == Base.encode64(png)

        Req.Test.json(conn, text_response_body())
      end)

      messages = [
        %{
          role: "user",
          content: "what is this?",
          image_parts: [%{type: :image, mime_type: "image/png", data: png}]
        }
      ]

      assert {:ok, _turn} = Messages.chat(messages, [], chat_opts())
    end

    test "an image-only user message omits the empty text block" do
      png = <<137, 80, 78, 71>>

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert [%{"role" => "user", "content" => [image_block]}] = decoded["messages"]
        assert image_block["type"] == "image"
        assert image_block["source"]["media_type"] == "image/png"
        assert image_block["source"]["data"] == Base.encode64(png)

        Req.Test.json(conn, text_response_body())
      end)

      messages = [
        %{
          role: "user",
          content: "",
          image_parts: [%{type: :image, mime_type: "image/png", data: png}]
        }
      ]

      assert {:ok, _turn} = Messages.chat(messages, [], chat_opts())
    end

    test "posts API-key headers and a cache-marked body" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert ["sk-ant-test"] = Plug.Conn.get_req_header(conn, "x-api-key")
        assert ["2023-06-01"] = Plug.Conn.get_req_header(conn, "anthropic-version")
        assert [] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.request_path == "/v1/messages"
        assert decoded["model"] == "claude-sonnet-4-6"
        assert decoded["max_tokens"] == 8192

        # System prompt becomes a cache-marked block list.
        assert decoded["system"] == [
                 %{
                   "type" => "text",
                   "text" => "You are helpful",
                   "cache_control" => %{"type" => "ephemeral"}
                 }
               ]

        # Last tool carries the cache breakpoint.
        assert [tool] = decoded["tools"]
        assert tool["name"] == "shell"
        assert tool["input_schema"]["type"] == "object"
        assert tool["cache_control"] == %{"type" => "ephemeral"}

        # Messages are block-form; the final message's final block is cache-marked.
        assert [%{"role" => "user", "content" => [block]}] = decoded["messages"]
        assert block["type"] == "text"
        assert block["text"] == "Hi"
        assert block["cache_control"] == %{"type" => "ephemeral"}

        Req.Test.json(conn, text_response_body())
      end)

      messages = [
        %{role: "system", content: "You are helpful"},
        %{role: "user", content: "Hi"}
      ]

      assert {:ok, turn} = Messages.chat(messages, [capability()], chat_opts())

      assert turn.content == "Hello there"
      assert turn.model == "claude-sonnet-4-6"
      assert turn.usage == %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
      assert turn.provider_state.system == "You are helpful"
      assert turn.provider_state.capabilities == [capability()]
      assert turn.provider_state.assistant_content == text_response_body()["content"]
      assert [%{role: "user"}] = turn.provider_state.messages
    end

    test "only the final message carries a cache breakpoint" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert [first, middle, last] = decoded["messages"]
        refute Enum.any?(first["content"], &Map.has_key?(&1, "cache_control"))
        refute Enum.any?(middle["content"], &Map.has_key?(&1, "cache_control"))
        assert List.last(last["content"])["cache_control"] == %{"type" => "ephemeral"}

        Req.Test.json(conn, text_response_body())
      end)

      messages = [
        %{role: "user", content: "First question"},
        %{role: "assistant", content: "First answer"},
        %{role: "user", content: "Second question"}
      ]

      assert {:ok, _turn} = Messages.chat(messages, [], chat_opts())
    end

    test "omits tools and system keys when absent" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        refute Map.has_key?(decoded, "tools")
        refute Map.has_key?(decoded, "system")

        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} =
               Messages.chat([%{role: "user", content: "compact this"}], [], chat_opts())
    end

    test "honors an explicit max_tokens override" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["max_tokens"] == 1
        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} =
               Messages.chat(
                 [%{role: "user", content: "."}],
                 [],
                 chat_opts(max_tokens: 1)
               )
    end

    test "sends output_config.effort when reasoning_effort is set" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["output_config"] == %{"effort" => "high"}
        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} =
               Messages.chat(
                 [%{role: "user", content: "."}],
                 [],
                 chat_opts(reasoning_effort: :high)
               )
    end

    test "omits output_config when reasoning_effort is unset" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        refute Map.has_key?(Jason.decode!(body), "output_config")
        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} = Messages.chat([%{role: "user", content: "."}], [], chat_opts())
    end

    test "includes temperature for models that accept sampling params" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["temperature"] == 0.2
        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} =
               Messages.chat(
                 [%{role: "user", content: "hi"}],
                 [],
                 chat_opts(temperature: 0.2)
               )
    end

    test "drops temperature for Claude 4.7+ models that reject sampling params" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        refute Map.has_key?(Jason.decode!(body), "temperature")
        Req.Test.json(conn, Map.put(text_response_body(), "model", "claude-opus-4-8"))
      end)

      assert {:ok, _turn} =
               Messages.chat(
                 [%{role: "user", content: "hi"}],
                 [],
                 chat_opts(model: "claude-opus-4-8", temperature: 0.2)
               )
    end

    test "returns an auth error without a credential" do
      assert {:error, {:provider_error, %{provider: :anthropic, kind: :auth, message: message}}} =
               Messages.chat([%{role: "user", content: "x"}], [], model: "claude-sonnet-4-6")

      assert message =~ ":api_key"
    end

    test "raises when no non-system messages remain" do
      assert_raise ArgumentError, ~r/non-system/, fn ->
        Messages.chat([%{role: "system", content: "only system"}], [], chat_opts())
      end
    end

    test "raises on a non-leading system message instead of silently re-roling it" do
      messages = [
        %{role: "system", content: "lead"},
        %{role: "user", content: "hi"},
        %{role: "system", content: "interleaved"}
      ]

      assert_raise ArgumentError, ~r/system messages to lead/, fn ->
        Messages.chat(messages, [], chat_opts())
      end
    end
  end

  defp error_chat(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, status, Jason.encode!(body))
    end)

    Messages.chat([%{role: "user", content: "x"}], [], chat_opts())
  end

  describe "continue/3 — tool result image blocks" do
    test "an image-bearing tool result becomes a tool_result content array (text + image block)" do
      png = <<137, 80, 78, 71>>
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})
        Req.Test.json(conn, text_response_body())
      end)

      provider_state = %{
        system: nil,
        messages: [%{role: "user", content: "Hi"}],
        assistant_content: [%{"type" => "text", "text" => "ok"}],
        tools: [],
        capabilities: []
      }

      tool_results = [
        %{
          call_id: "call_shot",
          output: "captured",
          images: [%{type: :image, mime_type: "image/png", data: png}]
        }
      ]

      assert {:ok, _turn} = Messages.continue(provider_state, tool_results, chat_opts())

      assert_receive {:body, decoded}
      user_msg = List.last(decoded["messages"])
      assert user_msg["role"] == "user"
      assert [block] = user_msg["content"]
      assert block["type"] == "tool_result"
      assert block["tool_use_id"] == "call_shot"
      assert [text_block, image_block] = block["content"]
      assert text_block == %{"type" => "text", "text" => "captured"}
      assert image_block["type"] == "image"
      assert image_block["source"]["media_type"] == "image/png"
      assert image_block["source"]["data"] == Base.encode64(png)
    end

    test "retention keeps only the most recent N tool_result screenshots; older bytes elided" do
      png = <<137, 80, 78, 71>>
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})
        Req.Test.json(conn, text_response_body())
      end)

      # Two prior tool_result screenshot messages in history + a fresh one this
      # turn → three; cap of 1 keeps only the newest's image block.
      encoded_image = %{
        type: "image",
        source: %{type: "base64", media_type: "image/png", data: Base.encode64(png)}
      }

      old_shot = %{
        role: "user",
        content: [
          %{
            type: "tool_result",
            tool_use_id: "old",
            content: [%{type: "text", text: "captured"}, encoded_image]
          }
        ]
      }

      provider_state = %{
        system: nil,
        messages: [%{role: "user", content: "Hi"}, old_shot, old_shot],
        assistant_content: [%{"type" => "text", "text" => "ok"}],
        tools: [],
        capabilities: []
      }

      tool_results = [
        %{
          call_id: "new",
          output: "captured",
          images: [%{type: :image, mime_type: "image/png", data: png}]
        }
      ]

      assert {:ok, _turn} =
               Messages.continue(
                 provider_state,
                 tool_results,
                 Keyword.put(chat_opts(), :max_retained_screenshots, 1)
               )

      assert_receive {:body, decoded}

      image_blocks =
        decoded["messages"]
        |> Enum.flat_map(fn m -> List.wrap(m["content"]) end)
        |> Enum.filter(&match?(%{"type" => "tool_result"}, &1))
        |> Enum.flat_map(fn tr -> tr["content"] |> List.wrap() |> Enum.filter(&is_map/1) end)
        |> Enum.filter(&(&1["type"] == "image"))

      # only the newest screenshot keeps an image block; the two older are elided
      # to a plain-string content (no image block survives there).
      assert length(image_blocks) == 1
    end

    test "a text-only tool result keeps a plain string content (byte-identical to pre-image)" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})
        Req.Test.json(conn, text_response_body())
      end)

      provider_state = %{
        system: nil,
        messages: [%{role: "user", content: "Hi"}],
        assistant_content: [%{"type" => "text", "text" => "ok"}],
        tools: [],
        capabilities: []
      }

      assert {:ok, _turn} =
               Messages.continue(provider_state, [%{call_id: "c", output: "plain"}], chat_opts())

      assert_receive {:body, decoded}
      block = decoded["messages"] |> List.last() |> Map.fetch!("content") |> hd()
      assert block["content"] == "plain"
    end
  end

  describe "chat/3 — error handling" do
    test "401 becomes a structured auth error" do
      assert {:error, {:provider_error, error}} =
               error_chat(401, %{
                 "type" => "error",
                 "error" => %{"type" => "authentication_error", "message" => "invalid x-api-key"}
               })

      assert error.provider == :anthropic
      assert error.adapter == :messages
      assert error.status == 401
      assert error.kind == :auth
      assert error.message == "invalid x-api-key"
    end

    test "429 becomes a rate-limit error" do
      assert {:error, {:provider_error, error}} =
               error_chat(429, %{
                 "type" => "error",
                 "error" => %{"type" => "rate_limit_error", "message" => "rate limited"}
               })

      assert error.kind == :rate_limit
    end

    test "529 overloaded becomes provider_unavailable" do
      assert {:error, {:provider_error, error}} =
               error_chat(529, %{
                 "type" => "error",
                 "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
               })

      assert error.kind == :provider_unavailable
    end

    test "402 billing becomes a quota error" do
      assert {:error, {:provider_error, error}} =
               error_chat(402, %{
                 "type" => "error",
                 "error" => %{"type" => "billing_error", "message" => "payment required"}
               })

      assert error.kind == :quota
    end

    test "prompt-too-long errors return bare :context_length_exceeded" do
      assert {:error, :context_length_exceeded} =
               error_chat(400, %{
                 "type" => "error",
                 "error" => %{
                   "type" => "invalid_request_error",
                   "message" => "prompt is too long: 213413 tokens > 200000 maximum"
                 }
               })
    end

    test "403 becomes a structured auth error" do
      assert {:error, {:provider_error, error}} =
               error_chat(403, %{
                 "type" => "error",
                 "error" => %{"type" => "permission_error", "message" => "forbidden"}
               })

      assert error.kind == :auth
      assert error.status == 403
    end

    test "413 request_too_large stays a structured provider error, not a context overflow" do
      # 413 is the raw 32 MB byte limit (Cloudflare edge), not a token
      # overflow — compaction advice would be wrong for it.
      assert {:error, {:provider_error, error}} =
               error_chat(413, %{
                 "type" => "error",
                 "error" => %{
                   "type" => "request_too_large",
                   "message" => "Request body too large"
                 }
               })

      assert error.status == 413
      assert error.kind == :provider
    end

    test "413 whose message mentions a context limit still stays a provider error" do
      # Status-gated, not message-matched: a 413 byte-limit error can carry a
      # message that name-drops the context limit / token count, but it is not a
      # token overflow and must keep its provider error (compaction won't help).
      assert {:error, {:provider_error, error}} =
               error_chat(413, %{
                 "type" => "error",
                 "error" => %{
                   "type" => "request_too_large",
                   "message" => "request exceeds the context limit with too many tokens"
                 }
               })

      assert error.status == 413
      assert error.kind == :provider
    end

    test "transport failures become structured transport errors" do
      result =
        Messages.chat(
          [%{role: "user", content: "x"}],
          [],
          chat_opts(
            req_options: [
              adapter: fn req -> {req, Req.TransportError.exception(reason: :timeout)} end
            ]
          )
        )

      assert {:error, {:provider_transport_error, error}} = result
      assert error.provider == :anthropic
      assert error.kind == :timeout
    end
  end

  describe "chat/3 — telemetry" do
    test "emits a provider call event with anthropic identity and correlation ids" do
      test_pid = self()
      handler_id = "anthropic-call-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("request-id", "req_abc123")
        |> Req.Test.json(text_response_body())
      end)

      assert {:ok, _turn} =
               Messages.chat(
                 [
                   %{role: "system", content: "sys"},
                   %{role: "user", content: "Hi"}
                 ],
                 [capability()],
                 chat_opts(session_id: "main-77", parent_session: "root-1")
               )

      assert_receive {:telemetry, [:fermix, :provider, :call], measurements,
                      %{adapter: :messages} = metadata}

      assert measurements.duration_ms >= 0
      assert metadata.provider == :anthropic
      assert metadata.auth_mode == :api_key
      assert metadata.model == "claude-sonnet-4-6"
      assert metadata.status == :ok
      assert metadata.tokens == %{prompt: 10, completion: 5}
      assert metadata.stop_reason == "end_turn"
      assert metadata.request_id == "req_abc123"
      assert metadata.session_id == "main-77"
      assert metadata.parent_session == "root-1"
      assert metadata.input_items == 1
      assert metadata.input_bytes > 0
      assert metadata.instructions_bytes == byte_size("sys")
      assert metadata.tools_count == 1
      assert metadata.capabilities_count == 1
    end

    test "emits error telemetry with the structured error detail" do
      test_pid = self()
      handler_id = "anthropic-error-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          429,
          Jason.encode!(%{"error" => %{"type" => "rate_limit_error", "message" => "slow down"}})
        )
      end)

      assert {:error, _reason} =
               Messages.chat([%{role: "user", content: "x"}], [], chat_opts())

      assert_receive {:telemetry, [:fermix, :provider, :call], _measurements,
                      %{adapter: :messages, error_status: 429} = metadata}

      assert metadata.status == :error
      assert metadata.error_kind == :rate_limit
      assert metadata.error == "slow down"
      # No request-id header on this response — the key is omitted, not nil.
      refute Map.has_key?(metadata, :request_id)
    end
  end

  describe "continue/3" do
    test "replays assistant tool_use blocks immediately followed by tool_result blocks" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})
        Req.Test.json(conn, text_response_body())
      end)

      provider_state = %{
        system: "sys",
        messages: [%{role: "user", content: [%{type: "text", text: "list files"}]}],
        assistant_content: tool_use_response_body()["content"],
        tools: Messages.to_provider_tools([capability()]),
        capabilities: [capability()],
        stop_reason: "tool_use"
      }

      assert {:ok, turn} =
               Messages.continue(
                 provider_state,
                 [%{call_id: "toolu_01", output: "README.md"}],
                 chat_opts()
               )

      assert_receive {:request_body, decoded}

      assert [user, assistant, results] = decoded["messages"]
      assert user["role"] == "user"

      assert assistant["role"] == "assistant"

      assert [%{"type" => "text"}, %{"type" => "tool_use", "id" => "toolu_01"}] =
               assistant["content"]

      assert results["role"] == "user"

      assert [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_01",
                 "content" => "README.md",
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ] = results["content"]

      # New provider_state folds the round into messages for the next replay.
      assert length(turn.provider_state.messages) == 3
      assert turn.provider_state.assistant_content == text_response_body()["content"]
    end

    test "two consecutive tool rounds accumulate the full transcript in order" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:request_body, decoded})
        Req.Test.json(conn, tool_use_response_body())
      end)

      {:ok, turn1} =
        Messages.chat([%{role: "user", content: "go"}], [capability()], chat_opts())

      assert_receive {:request_body, _round0}

      {:ok, turn2} =
        Messages.continue(
          turn1.provider_state,
          [%{call_id: "toolu_01", output: "out-1"}],
          chat_opts()
        )

      assert_receive {:request_body, _round1}

      {:ok, _turn3} =
        Messages.continue(
          turn2.provider_state,
          [%{call_id: "toolu_01", output: "out-2"}],
          chat_opts()
        )

      assert_receive {:request_body, round2}

      roles = Enum.map(round2["messages"], & &1["role"])
      assert roles == ["user", "assistant", "user", "assistant", "user"]

      [_, asst1, results1, asst2, results2] = round2["messages"]
      assert Enum.any?(asst1["content"], &(&1["type"] == "tool_use"))
      assert Enum.any?(asst2["content"], &(&1["type"] == "tool_use"))
      assert [%{"content" => "out-1"} = first_result] = results1["content"]
      assert [%{"content" => "out-2"} = second_result] = results2["content"]

      # Cache breakpoints must not accumulate across rounds (API allows max 4).
      refute Map.has_key?(first_result, "cache_control")
      assert second_result["cache_control"] == %{"type" => "ephemeral"}
    end

    test "rejects empty tool results" do
      assert_raise FunctionClauseError, fn ->
        Messages.continue(%{messages: [], assistant_content: []}, [], chat_opts())
      end
    end
  end

  describe "supports_streaming?/0" do
    test "is false — non-streaming with a bounded max_tokens" do
      refute Messages.supports_streaming?()
    end
  end

  # Stateless token-server stubs for OAuth-mode tests. The 401-retry test
  # distinguishes stale vs fresh bearers by header, so no state is needed.
  defmodule RefreshingTokenServer do
    def get_token("prof-retry"), do: {:ok, "stale-token"}
    def refresh("prof-retry"), do: {:ok, "fresh-token"}
  end

  defmodule RefusingTokenServer do
    def get_token("prof-dead"), do: {:ok, "dead-token"}
    def refresh("prof-dead"), do: {:error, :reauthorization_required}
  end

  defmodule ExplodingTokenServer do
    def get_token(_profile), do: raise("token server must not be called in api_key mode")
  end

  @claude_code_prefix "You are Claude Code, Anthropic's official CLI for Claude."

  defp oauth_opts(extra \\ []) do
    Keyword.merge(
      [
        access_token: "sub-token",
        model: "claude-sonnet-4-6",
        base_url: "https://api.anthropic.com/v1",
        req_options: [plug: {Req.Test, __MODULE__}]
      ],
      extra
    )
  end

  describe "chat/3 — OAuth mode" do
    test "sends Claude Code identity headers and bearer auth, never x-api-key" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert ["Bearer sub-token"] = Plug.Conn.get_req_header(conn, "authorization")
        assert [] = Plug.Conn.get_req_header(conn, "x-api-key")

        assert ["claude-code-20250219,oauth-2025-04-20"] =
                 Plug.Conn.get_req_header(conn, "anthropic-beta")

        assert ["2023-06-01"] = Plug.Conn.get_req_header(conn, "anthropic-version")
        assert ["cli"] = Plug.Conn.get_req_header(conn, "x-app")
        assert [ua] = Plug.Conn.get_req_header(conn, "user-agent")
        assert ua =~ ~r/^claude-cli\/.+ \(external, cli\)$/

        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} = Messages.chat([%{role: "user", content: "hi"}], [], oauth_opts())
    end

    test "prepends the Claude Code identity block ahead of the real system prompt" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert [prefix_block, system_block] = decoded["system"]
        assert prefix_block["text"] == @claude_code_prefix
        refute Map.has_key?(prefix_block, "cache_control")
        assert system_block["text"] == "You are helpful"
        assert system_block["cache_control"] == %{"type" => "ephemeral"}

        Req.Test.json(conn, text_response_body())
      end)

      messages = [
        %{role: "system", content: "You are helpful"},
        %{role: "user", content: "hi"}
      ]

      assert {:ok, _turn} = Messages.chat(messages, [], oauth_opts())
    end

    test "the identity block is the sole, cache-marked system block without a system prompt" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert [prefix_block] = decoded["system"]
        assert prefix_block["text"] == @claude_code_prefix
        assert prefix_block["cache_control"] == %{"type" => "ephemeral"}

        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} = Messages.chat([%{role: "user", content: "hi"}], [], oauth_opts())
    end

    test "prefixes tool names with mcp_ on the wire and restores them on parse" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert [tool] = decoded["tools"]
        assert tool["name"] == "mcp_shell"

        response =
          tool_use_response_body()
          |> update_in(["content"], fn blocks ->
            Enum.map(blocks, fn
              %{"type" => "tool_use"} = block -> Map.put(block, "name", "mcp_shell")
              block -> block
            end)
          end)

        Req.Test.json(conn, response)
      end)

      assert {:ok, turn} =
               Messages.chat([%{role: "user", content: "go"}], [capability()], oauth_opts())

      assert [%{name: "shell", call_id: "toolu_01"}] = turn.tool_calls
    end

    test "does not double-prefix capability names already starting with mcp_" do
      mcp_capability =
        Capability.new(%{
          name: "mcp_github_search",
          description: "Search GitHub via MCP.",
          parameters: %{"type" => "object", "properties" => %{}},
          kind: :mcp,
          policy_class: :read_only,
          executor: {Mod, :run, []}
        })

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert [tool] = decoded["tools"]
        assert tool["name"] == "mcp_github_search"

        response =
          tool_use_response_body()
          |> update_in(["content"], fn blocks ->
            Enum.map(blocks, fn
              %{"type" => "tool_use"} = block -> Map.put(block, "name", "mcp_github_search")
              block -> block
            end)
          end)

        Req.Test.json(conn, response)
      end)

      assert {:ok, turn} =
               Messages.chat([%{role: "user", content: "go"}], [mcp_capability], oauth_opts())

      assert [%{name: "mcp_github_search"}] = turn.tool_calls
    end

    test "fetches the bearer through the token server and tags telemetry with oauth" do
      test_pid = self()
      handler_id = "anthropic-oauth-call-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        assert ["Bearer stale-token"] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, text_response_body())
      end)

      opts =
        oauth_opts(token_server: RefreshingTokenServer, auth_profile: "prof-retry")
        |> Keyword.delete(:access_token)

      assert {:ok, _turn} = Messages.chat([%{role: "user", content: "hi"}], [], opts)

      assert_receive {:telemetry, [:fermix, :provider, :call], _measurements,
                      %{adapter: :messages, auth_mode: :oauth} = metadata}

      assert metadata.provider == :anthropic
      assert metadata.status == :ok
    end

    test "a 401 refreshes through the token server and retries exactly once" do
      Req.Test.stub(__MODULE__, fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer stale-token"] ->
            Plug.Conn.send_resp(
              conn,
              401,
              Jason.encode!(%{
                "error" => %{"type" => "authentication_error", "message" => "token expired"}
              })
            )

          ["Bearer fresh-token"] ->
            Req.Test.json(conn, text_response_body())
        end
      end)

      opts =
        oauth_opts(token_server: RefreshingTokenServer, auth_profile: "prof-retry")
        |> Keyword.delete(:access_token)

      assert {:ok, turn} = Messages.chat([%{role: "user", content: "hi"}], [], opts)
      assert turn.content == "Hello there"
    end

    test "the 401-refresh-retry emits exactly one telemetry event for the logical call" do
      test_pid = self()
      handler_id = "anthropic-retry-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer stale-token"] ->
            Plug.Conn.send_resp(
              conn,
              401,
              Jason.encode!(%{
                "error" => %{"type" => "authentication_error", "message" => "token expired"}
              })
            )

          ["Bearer fresh-token"] ->
            Req.Test.json(conn, text_response_body())
        end
      end)

      opts =
        oauth_opts(token_server: RefreshingTokenServer, auth_profile: "prof-retry")
        |> Keyword.delete(:access_token)

      assert {:ok, _turn} = Messages.chat([%{role: "user", content: "hi"}], [], opts)

      assert_receive {:telemetry, [:fermix, :provider, :call], _measurements,
                      %{adapter: :messages, auth_mode: :oauth, status: :ok}}

      # No phantom error event for the refreshed 401 (Codex precedent:
      # one emit per logical call).
      refute_receive {:telemetry, [:fermix, :provider, :call], _m,
                      %{adapter: :messages, error_status: 401}},
                     100
    end

    test "OAuth tool prefixing fails loud on wire-name collisions" do
      colliding =
        Capability.new(%{
          name: "mcp_shell",
          description: "Collides with the prefixed builtin shell.",
          parameters: %{"type" => "object", "properties" => %{}},
          kind: :builtin,
          policy_class: :exec,
          executor: {Mod, :run, []}
        })

      assert_raise ArgumentError, ~r/collided/, fn ->
        Messages.chat([%{role: "user", content: "go"}], [capability(), colliding], oauth_opts())
      end
    end

    test "permanent refresh failure surfaces the original auth error tagged with oauth" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          401,
          Jason.encode!(%{
            "error" => %{"type" => "authentication_error", "message" => "token expired"}
          })
        )
      end)

      opts =
        oauth_opts(token_server: RefusingTokenServer, auth_profile: "prof-dead")
        |> Keyword.delete(:access_token)

      assert {:error, {:provider_error, error}} =
               Messages.chat([%{role: "user", content: "hi"}], [], opts)

      assert error.kind == :auth
      assert error.status == 401
      assert error.auth_mode == :oauth
    end

    test "api-key mode never touches the token server and never prefixes tools" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert ["sk-ant-test"] = Plug.Conn.get_req_header(conn, "x-api-key")
        assert [] = Plug.Conn.get_req_header(conn, "authorization")
        assert [] = Plug.Conn.get_req_header(conn, "anthropic-beta")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert [%{"name" => "shell"}] = Jason.decode!(body)["tools"]

        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} =
               Messages.chat(
                 [%{role: "user", content: "hi"}],
                 [capability()],
                 chat_opts(token_server: ExplodingTokenServer, auth_profile: "unused")
               )
    end
  end
end
