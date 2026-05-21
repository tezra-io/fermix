defmodule FermixCore.Providers.OpenAI.CodexTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Providers.OpenAI.Codex

  defmodule StubTokenServer do
    @moduledoc false
    use GenServer

    def init(reply), do: {:ok, reply}
    def handle_call(:get_token, _from, reply), do: {:reply, reply, reply}
  end

  defmodule RefreshingTokenServer do
    @moduledoc false
    use GenServer

    def init(tokens), do: {:ok, tokens}

    def handle_call(:get_token, _from, %{current: current} = state) do
      {:reply, {:ok, current}, state}
    end

    def handle_call(:refresh, _from, %{refreshed: refreshed} = state) do
      {:reply, {:ok, refreshed}, %{state | current: refreshed}}
    end
  end

  defmodule InvalidatedTokenServer do
    @moduledoc false
    use GenServer

    def init(token), do: {:ok, token}
    def handle_call(:get_token, _from, t), do: {:reply, {:ok, t}, t}
    def handle_call(:refresh, _from, t), do: {:reply, {:error, :auth_invalidated}, t}
  end

  defmodule FailingRefreshTokenServer do
    @moduledoc false
    use GenServer

    def init(state), do: {:ok, state}
    def handle_call(:get_token, _from, %{token: token} = state), do: {:reply, {:ok, token}, state}

    def handle_call(:refresh, _from, %{reason: reason} = state),
      do: {:reply, {:error, reason}, state}
  end

  # JWT with payload {"sub":"usr_1"} — base64url-encoded, no padding.
  @jwt_with_sub "header.eyJzdWIiOiJ1c3JfMSJ9.sig"

  defp capability(name \\ "echo") do
    Capability.new(%{
      name: name,
      description: "Echo input back",
      parameters: %{type: "object", properties: %{text: %{type: "string"}}, required: ["text"]},
      kind: :builtin,
      executor: {Kernel, :inspect, []}
    })
  end

  describe "to_provider_tools/1" do
    test "produces flat function shape — Codex uses the same tool shape as Responses" do
      [tool] = Codex.to_provider_tools([capability()])

      assert tool.type == "function"
      assert tool.name == "echo"
      assert tool.strict == false
    end

    test "returns [] for []" do
      assert Codex.to_provider_tools([]) == []
    end
  end

  describe "supports_streaming?/0" do
    test "returns true" do
      assert Codex.supports_streaming?()
    end
  end

  describe "chat/3 — request shape" do
    test "emits provider telemetry with request shape" do
      test_pid = self()
      handler_id = "test-codex-request-shape-#{System.unique_integer()}"

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
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, terminal_message_sse("ok"))
      end)

      assert {:ok, _turn} =
               Codex.chat(
                 [
                   %{role: "system", content: "be terse"},
                   %{role: "user", content: "Hi"}
                 ],
                 [capability()],
                 access_token: @jwt_with_sub,
                 model: "gpt-5",
                 base_url: "https://chatgpt.test/codex/responses",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      assert_receive {:telemetry, [:fermix, :provider, :call], measurements, metadata}
      assert measurements.duration_ms >= 0
      assert metadata.input_items == 1
      assert metadata.input_bytes > 0
      assert metadata.instructions_bytes == byte_size("be terse")
      assert metadata.tools_count == 1
      assert metadata.tools_bytes > 0
      assert metadata.capabilities_count == 1
    end

    test "posts SSE-streaming body to Codex URL with bearer token + tools" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "gpt-5"
        assert decoded["stream"] == true
        assert decoded["store"] == false
        assert is_list(decoded["input"])
        assert [tool] = decoded["tools"]
        assert tool["name"] == "echo"
        assert tool["type"] == "function"

        assert Plug.Conn.get_req_header(conn, "openai-beta") == ["responses=experimental"]
        assert Plug.Conn.get_req_header(conn, "originator") == ["pi"]
        assert Plug.Conn.get_req_header(conn, "chatgpt-account-id") == ["usr_1"]

        sse = """
        data: {"type":"response.output_text.delta","delta":"hello "}

        data: {"type":"response.output_text.delta","delta":"world"}

        data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":3,"output_tokens":2}}}

        data: [DONE]

        """

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      messages = [
        %{role: "system", content: "be terse"},
        %{role: "user", content: "Hi"}
      ]

      {:ok, turn} =
        Codex.chat(messages, [capability()],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert turn.usage.prompt_tokens == 3
      assert turn.usage.completion_tokens == 2
      assert turn.usage.total_tokens == 5
      assert turn.model == "gpt-5"
    end

    test "logs debug context when the token is not a decodable JWT account id source" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "chatgpt-account-id") == []

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, terminal_message_sse("ok"))
      end)

      previous_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        try do
          capture_log([level: :debug], fn ->
            assert {:ok, _turn} =
                     Codex.chat([%{role: "user", content: "x"}], [],
                       access_token: "not-a-jwt",
                       model: "gpt-5",
                       base_url: "https://chatgpt.test/codex/responses",
                       req_options: [plug: {Req.Test, __MODULE__}]
                     )
          end)
        after
          Logger.configure(level: previous_level)
        end

      assert log =~ "Codex account id decode skipped"
      assert log =~ "missing_payload"
    end

    test "raises ArgumentError when token_server returns {:error, _}" do
      stub_server = :"codex_test_stub_token_server_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        GenServer.start_link(
          FermixCore.Providers.OpenAI.CodexTest.StubTokenServer,
          {:error, :no_token},
          name: stub_server
        )

      assert_raise ArgumentError, ~r/Codex auth required/, fn ->
        Codex.chat([%{role: "user", content: "x"}], [],
          model: "gpt-5",
          token_server: stub_server
        )
      end
    end

    test "returns {:error, _} on a non-200 response" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 401, "unauthorized")
      end)

      {:error, message} =
        Codex.chat([%{role: "user", content: "x"}], [],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert message == "Codex API error: 401"
    end

    test "provider telemetry includes the agent when supplied" do
      telemetry_id = "codex-provider-agent-#{System.unique_integer([:positive])}"

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
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, terminal_message_sse("hello"))
      end)

      {:ok, _turn} =
        Codex.chat([%{role: "user", content: "x"}], [],
          agent: "main",
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert_receive {:telemetry, [:fermix, :provider, :call], _measurements, metadata}
      assert metadata.agent == "main"
    end

    test "refreshes token and retries once when Codex invalidates cached bearer" do
      test_id = :"codex_refresh_retry_#{System.unique_integer([:positive])}"
      parent = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      old_token = "header.eyJzdWIiOiJvbGRfdXNlciJ9.sig"
      new_token = "header.eyJzdWIiOiJuZXdfdXNlciJ9.sig"

      token_server = :"codex_refresh_token_server_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        GenServer.start_link(
          FermixCore.Providers.OpenAI.CodexTest.RefreshingTokenServer,
          %{current: old_token, refreshed: new_token},
          name: token_server
        )

      Req.Test.stub(test_id, fn conn ->
        attempt = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
        send(parent, {:attempt, attempt, Plug.Conn.get_req_header(conn, "authorization")})

        case attempt do
          1 ->
            Plug.Conn.send_resp(
              conn,
              401,
              Jason.encode!(%{
                "error" => %{
                  "message" => "Your authentication token has been invalidated.",
                  "code" => "token_invalidated"
                }
              })
            )

          2 ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
            |> Plug.Conn.send_resp(200, terminal_message_sse("refreshed"))
        end
      end)

      {:ok, turn} =
        Codex.chat([%{role: "user", content: "x"}], [],
          token_server: token_server,
          model: "gpt-5.5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, test_id}]
        )

      assert turn.content == "refreshed"
      assert_receive {:attempt, 1, ["Bearer " <> ^old_token]}, 500
      assert_receive {:attempt, 2, ["Bearer " <> ^new_token]}, 500
    end

    test "surfaces a recovery message when TokenManager reports auth_invalidated" do
      token_server = :"codex_invalidated_token_server_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        GenServer.start_link(
          InvalidatedTokenServer,
          "header.eyJzdWIiOiJ1c3JfMSJ9.sig",
          name: token_server
        )

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          401,
          Jason.encode!(%{
            "error" => %{
              "code" => "token_invalidated",
              "message" => "Your authentication token has been invalidated."
            }
          })
        )
      end)

      {:error, message} =
        Codex.chat([%{role: "user", content: "x"}], [],
          token_server: token_server,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert message =~ "Codex auth invalidated"
      assert message =~ "fermix auth login"
    end

    test "surfaces refresh failures instead of returning the original 401" do
      token_server = :"codex_refresh_failure_token_server_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        GenServer.start_link(
          FailingRefreshTokenServer,
          %{token: "header.eyJzdWIiOiJ1c3JfMSJ9.sig", reason: {:network, :timeout}},
          name: token_server
        )

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          401,
          Jason.encode!(%{
            "error" => %{
              "code" => "token_invalidated",
              "message" => "Your authentication token has been invalidated."
            }
          })
        )
      end)

      {:error, message} =
        Codex.chat([%{role: "user", content: "x"}], [],
          token_server: token_server,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert message =~ "Codex token refresh failed"
      assert message =~ ":timeout"
      refute message == "Codex API error: 401"
    end
  end

  describe "chat/3 — reasoning effort body shape" do
    test "omits the reasoning field when :reasoning_effort is nil" do
      assert {nil, decoded} = run_chat_capture_body(reasoning_effort: nil)
      refute Map.has_key?(decoded, "reasoning")
    end

    test "omits the reasoning field when :reasoning_effort is :none" do
      assert {nil, decoded} = run_chat_capture_body(reasoning_effort: :none)
      refute Map.has_key?(decoded, "reasoning")
    end

    test "sends reasoning: %{effort: <level>} for each valid non-:none level" do
      for level <- [:minimal, :low, :medium, :high, :xhigh] do
        assert {nil, decoded} = run_chat_capture_body(reasoning_effort: level)
        assert decoded["reasoning"] == %{"effort" => Atom.to_string(level), "summary" => "auto"}
        assert decoded["include"] == ["reasoning.encrypted_content"]
      end
    end

    test "sends strict text.format schema when supplied" do
      assert {nil, decoded} =
               run_chat_capture_body(
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

    test "raises ArgumentError for an invalid effort level (caught at body construction)" do
      assert_raise ArgumentError, ~r/invalid reasoning_effort: :weird/, fn ->
        Codex.chat([%{role: "user", content: "x"}], [],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          reasoning_effort: :weird,
          base_url: "https://chatgpt.test/codex/responses"
        )
      end
    end

    test "continue/3 also re-sends reasoning when :reasoning_effort is set in opts" do
      test_id = :"codex_continue_reasoning_#{System.unique_integer([:positive])}"
      parent = self()

      Req.Test.stub(test_id, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:captured_body, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, terminal_message_sse("ok"))
      end)

      provider_state = %{
        input: [%{role: "user", content: [%{type: "input_text", text: "Hi"}]}],
        output_items: [
          %{
            "type" => "function_call",
            "id" => "fc_x",
            "call_id" => "call_x",
            "name" => "echo",
            "arguments" => "{}"
          }
        ],
        tools: [],
        capabilities: [],
        instructions: "be terse"
      }

      {:ok, _turn} =
        Codex.continue(provider_state, [%{call_id: "call_x", output: "ok"}],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          reasoning_effort: :high,
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, test_id}]
        )

      assert_receive {:captured_body, decoded}, 500
      assert decoded["reasoning"] == %{"effort" => "high", "summary" => "auto"}
      assert decoded["include"] == ["reasoning.encrypted_content"]
    end
  end

  describe "chat/3 — SSE fixture: single function_call" do
    test "parses one tool call from output_item.done with full arguments inline" do
      sse = """
      data: {"type":"response.created","response":{"model":"gpt-5"}}

      data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"echo","arguments":""}}

      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"echo","arguments":"{\\"text\\":\\"hi\\"}"}}

      data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":4,"output_tokens":6}}}

      data: [DONE]

      """

      {:ok, turn} = run_chat(sse)

      assert [%{name: "echo", call_id: "call_a", arguments: args}] = turn.tool_calls
      assert Jason.decode!(args) == %{"text" => "hi"}
      assert turn.content == ""
      assert turn.provider_state.capabilities == [capability()]
      assert turn.provider_state.tools != []
    end
  end

  describe "chat/3 — SSE fixture: function_call assembled from deltas" do
    test "assembles function_call.arguments from function_call_arguments.delta when item.arguments is empty" do
      sse = """
      data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_b","call_id":"call_b","name":"echo","arguments":""}}

      data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\"text\\":"}

      data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"\\"streamed\\"}"}

      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_b","call_id":"call_b","name":"echo","arguments":""}}

      data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":2,"output_tokens":3}}}

      data: [DONE]

      """

      {:ok, turn} = run_chat(sse)

      assert [%{call_id: "call_b", arguments: args}] = turn.tool_calls
      assert Jason.decode!(args) == %{"text" => "streamed"}
    end
  end

  describe "chat/3 — SSE fixture: parallel function_calls" do
    test "preserves output_index order across multiple tool calls" do
      sse = """
      data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_0","call_id":"call_0","name":"echo","arguments":"{\\"text\\":\\"a\\"}"}}

      data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"echo","arguments":"{\\"text\\":\\"b\\"}"}}

      data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"echo","arguments":"{\\"text\\":\\"b\\"}"}}

      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_0","call_id":"call_0","name":"echo","arguments":"{\\"text\\":\\"a\\"}"}}

      data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":1,"output_tokens":2}}}

      data: [DONE]

      """

      {:ok, turn} = run_chat(sse)

      assert [
               %{call_id: "call_0", arguments: arg0},
               %{call_id: "call_1", arguments: arg1}
             ] = turn.tool_calls

      assert Jason.decode!(arg0) == %{"text" => "a"}
      assert Jason.decode!(arg1) == %{"text" => "b"}
    end
  end

  describe "chat/3 — SSE fixture: function_call + reasoning + final message" do
    test "preserves reasoning items and tool call alongside text" do
      sse = """
      data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1","encrypted_content":"opaque"}}

      data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","encrypted_content":"opaque"}}

      data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_x","call_id":"call_x","name":"echo","arguments":"{\\"text\\":\\"hi\\"}"}}

      data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_x","call_id":"call_x","name":"echo","arguments":"{\\"text\\":\\"hi\\"}"}}

      data: {"type":"response.output_item.added","output_index":2,"item":{"type":"message","id":"msg_1","content":[]}}

      data: {"type":"response.output_text.delta","output_index":2,"delta":"done"}

      data: {"type":"response.output_item.done","output_index":2,"item":{"type":"message","id":"msg_1","content":[{"type":"output_text","text":"done"}]}}

      data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":3,"output_tokens":5}}}

      data: [DONE]

      """

      {:ok, turn} = run_chat(sse)

      assert [%{call_id: "call_x"}] = turn.tool_calls
      assert turn.content == "done"

      types = Enum.map(turn.provider_state.output_items, & &1["type"])
      assert types == ["reasoning", "function_call", "message"]

      [reasoning | _] = turn.provider_state.output_items
      assert reasoning["encrypted_content"] == "opaque"
    end
  end

  describe "chat/3 — SSE fixture: completion-only (no items)" do
    test "returns empty content and tool_calls when stream finishes without output items" do
      sse = """
      data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":1,"output_tokens":0}}}

      data: [DONE]

      """

      {:ok, turn} = run_chat(sse)

      assert turn.tool_calls == []
      assert turn.content == ""
      assert turn.usage.prompt_tokens == 1
    end
  end

  describe "continue/3" do
    test "next request: input = prior_input ++ output_items ++ function_call_outputs, with instructions resent" do
      test_id = :"codex_continue_#{System.unique_integer([:positive])}"

      Req.Test.stub(test_id, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["stream"] == true
        assert decoded["store"] == false
        assert decoded["instructions"] == "be terse"
        types = Enum.map(decoded["input"], &(&1["type"] || &1["role"]))
        assert "function_call" in types
        assert "function_call_output" in types
        assert "user" in types

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, terminal_message_sse("all done"))
      end)

      provider_state = %{
        input: [%{role: "user", content: [%{type: "input_text", text: "Hi"}]}],
        output_items: [
          %{
            "type" => "function_call",
            "id" => "fc_x",
            "call_id" => "call_x",
            "name" => "echo",
            "arguments" => "{\"text\":\"hi\"}"
          }
        ],
        tools: [],
        capabilities: [capability()],
        instructions: "be terse"
      }

      {:ok, turn} =
        Codex.continue(provider_state, [%{call_id: "call_x", output: "echoed"}],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, test_id}]
        )

      assert turn.content == "all done"
      assert turn.tool_calls == []
    end

    test "continuation strips persisted item ids and drops unreplayable reasoning items" do
      test_id = :"codex_reasoning_passthrough_#{System.unique_integer([:positive])}"

      reasoning_item = %{
        "type" => "reasoning",
        "id" => "rs_1",
        "encrypted_content" => "opaque",
        "summary" => []
      }

      id_only_reasoning_item = %{"type" => "reasoning", "id" => "rs_missing_encrypted"}

      function_call_item = %{
        "type" => "function_call",
        "id" => "fc_x",
        "call_id" => "call_x",
        "name" => "echo",
        "arguments" => "{\"text\":\"hi\"}"
      }

      Req.Test.stub(test_id, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        carried_items =
          Enum.filter(decoded["input"], fn item ->
            item["type"] in ["reasoning", "function_call"]
          end)

        assert carried_items == [
                 %{"type" => "reasoning", "encrypted_content" => "opaque", "summary" => []},
                 %{
                   "type" => "function_call",
                   "call_id" => "call_x",
                   "name" => "echo",
                   "arguments" => "{\"text\":\"hi\"}"
                 }
               ]

        refute Enum.any?(decoded["input"], &(&1["id"] == "rs_1"))
        refute Enum.any?(decoded["input"], &(&1["id"] == "rs_missing_encrypted"))
        refute Enum.any?(decoded["input"], &(&1["id"] == "fc_x"))

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, terminal_message_sse("ok"))
      end)

      provider_state = %{
        input: [%{role: "user", content: [%{type: "input_text", text: "Hi"}]}],
        output_items: [reasoning_item, id_only_reasoning_item, function_call_item],
        tools: [],
        capabilities: [capability()],
        instructions: "be terse"
      }

      {:ok, _turn} =
        Codex.continue(provider_state, [%{call_id: "call_x", output: "done"}],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, test_id}]
        )
    end

    test "returns actionable error when Codex rejects a stale persisted item id" do
      test_id = :"codex_store_disabled_#{System.unique_integer([:positive])}"

      Req.Test.stub(test_id, fn conn ->
        Plug.Conn.send_resp(
          conn,
          404,
          Jason.encode!(%{
            "error" => %{
              "message" =>
                "Item with id 'rs_1' not found. Items are not persisted when `store` is set to false."
            }
          })
        )
      end)

      provider_state = %{
        input: [%{role: "user", content: [%{type: "input_text", text: "Hi"}]}],
        output_items: [%{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "opaque"}],
        tools: [],
        capabilities: [],
        instructions: "be terse"
      }

      assert {:error, message} =
               Codex.continue(provider_state, [%{call_id: "call_x", output: "done"}],
                 access_token: @jwt_with_sub,
                 model: "gpt-5",
                 base_url: "https://chatgpt.test/codex/responses",
                 req_options: [plug: {Req.Test, test_id}]
               )

      assert message =~ "store=false"
      assert message =~ "Restart"
    end

    test "chat/3 stores instructions in provider_state so continue/3 can re-send them" do
      test_id = :"codex_instructions_capture_#{System.unique_integer([:positive])}"

      Req.Test.stub(test_id, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, terminal_message_sse("ok"))
      end)

      messages = [
        %{role: "system", content: "stay terse"},
        %{role: "user", content: "Hi"}
      ]

      {:ok, turn} =
        Codex.chat(messages, [],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, test_id}]
        )

      assert turn.provider_state.instructions == "stay terse"
    end

    test "chat/3 stores @default_instructions when no system message is present" do
      test_id = :"codex_default_instructions_#{System.unique_integer([:positive])}"

      Req.Test.stub(test_id, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, terminal_message_sse("ok"))
      end)

      {:ok, turn} =
        Codex.chat([%{role: "user", content: "Hi"}], [],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, test_id}]
        )

      assert is_binary(turn.provider_state.instructions)
      assert turn.provider_state.instructions != ""
    end
  end

  describe "chat/3 — streaming wiring" do
    test "SSE delivered as multiple chunks via send_chunked is reassembled by the parser" do
      sse = terminal_message_sse("chunked-ok")
      mid = div(byte_size(sse), 2)
      <<part1::binary-size(mid), part2::binary>> = sse

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_chunked(200)
        |> chunk!(part1)
        |> chunk!(part2)
      end)

      {:ok, turn} =
        Codex.chat([%{role: "user", content: "x"}], [],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert turn.content == "chunked-ok"
      assert turn.model == "gpt-5"
    end
  end

  describe "chat/3 — transport errors" do
    test ":closed becomes an actionable operator-readable message" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :closed)
      end)

      {:error, message} =
        Codex.chat([%{role: "user", content: "x"}], [],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert is_binary(message)
      assert message =~ "closed by peer"
      assert message =~ "reasoning_effort"
    end

    test ":timeout becomes an actionable operator-readable message" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      {:error, message} =
        Codex.chat([%{role: "user", content: "x"}], [],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert is_binary(message)
      assert message =~ "no data for"
      assert message =~ "receive_timeout"
    end

    test ":closed retries once and succeeds on the second attempt (stale-pool recovery)" do
      test_id = :"codex_stale_pool_#{System.unique_integer([:positive])}"
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      parent = self()

      Req.Test.stub(test_id, fn conn ->
        attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
        send(parent, {:codex_attempt, attempt})

        case attempt do
          1 ->
            Req.Test.transport_error(conn, :closed)

          _ ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
            |> Plug.Conn.send_resp(200, terminal_message_sse("recovered"))
        end
      end)

      {:ok, turn} =
        Codex.chat([%{role: "user", content: "x"}], [],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, test_id}]
        )

      assert turn.content == "recovered"
      assert_received {:codex_attempt, 1}
      assert_received {:codex_attempt, 2}
      refute_received {:codex_attempt, 3}
    end

    test ":closed retries exactly once; a second :closed surfaces as the actionable error" do
      test_id = :"codex_stale_pool_exhaust_#{System.unique_integer([:positive])}"
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      parent = self()

      Req.Test.stub(test_id, fn conn ->
        attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
        send(parent, {:codex_attempt, attempt})
        Req.Test.transport_error(conn, :closed)
      end)

      {:error, message} =
        Codex.chat([%{role: "user", content: "x"}], [],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, test_id}]
        )

      assert message =~ "closed by peer"
      assert_received {:codex_attempt, 1}
      assert_received {:codex_attempt, 2}
      refute_received {:codex_attempt, 3}
    end

    test ":timeout does NOT retry — single attempt, error surfaces" do
      test_id = :"codex_no_retry_timeout_#{System.unique_integer([:positive])}"
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      parent = self()

      Req.Test.stub(test_id, fn conn ->
        attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
        send(parent, {:codex_attempt, attempt})
        Req.Test.transport_error(conn, :timeout)
      end)

      {:error, _message} =
        Codex.chat([%{role: "user", content: "x"}], [],
          access_token: @jwt_with_sub,
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, test_id}]
        )

      assert_received {:codex_attempt, 1}
      refute_received {:codex_attempt, 2}
    end
  end

  describe "parse_response/1" do
    test "extracts text from a body shape (already-parsed map)" do
      body = %{
        "model" => "gpt-5",
        "output" => [
          %{
            "type" => "message",
            "id" => "msg_1",
            "content" => [%{"type" => "output_text", "text" => "ok"}]
          }
        ],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

      turn = Codex.parse_response(body)
      assert turn.content == "ok"
      assert turn.tool_calls == []
    end
  end

  defp run_chat_capture_body(opts) do
    test_id = :"codex_capture_#{System.unique_integer([:positive])}"
    parent = self()

    Req.Test.stub(test_id, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:captured_body, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_resp(200, terminal_message_sse("ok"))
    end)

    {:ok, _turn} =
      Codex.chat(
        [%{role: "user", content: "Hi"}],
        [],
        Keyword.merge(
          [
            access_token: @jwt_with_sub,
            model: "gpt-5",
            base_url: "https://chatgpt.test/codex/responses",
            req_options: [plug: {Req.Test, test_id}]
          ],
          opts
        )
      )

    receive do
      {:captured_body, decoded} -> {nil, decoded}
    after
      500 -> flunk("no body captured")
    end
  end

  defp chunk!(conn, data) do
    {:ok, conn} = Plug.Conn.chunk(conn, data)
    conn
  end

  defp terminal_message_sse(text) do
    """
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_z","content":[]}}

    data: {"type":"response.output_text.delta","output_index":0,"delta":"#{text}"}

    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_z","content":[{"type":"output_text","text":"#{text}"}]}}

    data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":1,"output_tokens":1}}}

    data: [DONE]

    """
  end

  defp run_chat(sse) do
    test_id = :"codex_chat_#{System.unique_integer([:positive])}"

    Req.Test.stub(test_id, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_resp(200, sse)
    end)

    Codex.chat(
      [%{role: "user", content: "Hi"}],
      [capability()],
      access_token: @jwt_with_sub,
      model: "gpt-5",
      base_url: "https://chatgpt.test/codex/responses",
      req_options: [plug: {Req.Test, test_id}]
    )
  end
end
