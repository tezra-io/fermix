defmodule FermixCore.Providers.OpenAI.ChatGPTPlanTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Prompt.ModelOverlays
  alias FermixCore.Providers.OpenAI.ChatGPTPlan

  # Fields the plan-usage route refuses (M57 D5; protocol reference §5.4).
  @forbidden ~w(temperature top_p max_output_tokens metadata user truncation background
                previous_response_id service_tier tools conversation prompt)

  # Headers that would name another client, account or credential.
  @foreign_headers ~w(originator chatgpt-account-id openai-beta openai-organization
                      openai-project x-api-key api-key)

  @usage_limit "Your ChatGPT plan's usage limit for Fermix is reached. Review your plan or " <>
                 "Fermix's limit in ChatGPT settings: https://chatgpt.com/settings/usage"

  defmodule RefreshingTokenServer do
    @moduledoc false
    def get_token("chatgpt"), do: {:ok, "stale-token"}

    def refresh("chatgpt") do
      send(self(), :refreshed)
      {:ok, "fresh-token"}
    end
  end

  defmodule RefusingTokenServer do
    @moduledoc false
    def get_token("chatgpt"), do: {:ok, "dead-token"}

    def refresh("chatgpt") do
      send(self(), :refreshed)
      {:error, :reauthorization_required}
    end
  end

  defp capability do
    Capability.new(%{
      name: "echo",
      description: "Echo input back",
      parameters: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      kind: :builtin,
      policy_class: :read_only,
      executor: {Kernel, :inspect, []}
    })
  end

  defp messages do
    [%{role: "system", content: "You are Fermix."}, %{role: "user", content: "Hi"}]
  end

  defp stub_id, do: :"chatgpt_plan_#{System.unique_integer([:positive])}"

  defp opts(stub, extra \\ []) do
    Keyword.merge(
      [
        access_token: "plan-token",
        model: "gpt-6.1-sol",
        base_url: "https://api.openai.com/v1",
        req_options: [plug: {Req.Test, stub}]
      ],
      extra
    )
  end

  defp oauth_opts(stub, server, extra \\ []) do
    stub
    |> opts(extra)
    |> Keyword.delete(:access_token)
    |> Keyword.merge(token_server: server, auth_profile: "chatgpt")
  end

  defp event(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp message_events(text) do
    event(%{
      "type" => "response.output_item.added",
      "output_index" => 0,
      "item" => %{"type" => "message", "id" => "msg_1", "content" => []}
    }) <>
      event(%{"type" => "response.output_text.delta", "output_index" => 0, "delta" => text}) <>
      event(%{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "message",
          "id" => "msg_1",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      })
  end

  defp completed do
    event(%{
      "type" => "response.completed",
      "response" => %{
        "model" => "gpt-6.1-sol",
        "status" => "completed",
        "usage" => %{"input_tokens" => 11, "output_tokens" => 2}
      }
    })
  end

  defp failed(code, extra \\ %{}) do
    event(%{
      "type" => "response.failed",
      "response" => %{
        "status" => "failed",
        "error" => Map.merge(%{"code" => code, "message" => "ChatGPT says #{code}"}, extra)
      }
    })
  end

  defp stream(stub, sse, content_type \\ "text/event-stream") do
    Req.Test.stub(stub, fn conn ->
      conn
      |> maybe_content_type(content_type)
      |> Plug.Conn.send_resp(200, sse)
    end)
  end

  defp maybe_content_type(conn, nil), do: conn
  defp maybe_content_type(conn, type), do: Plug.Conn.put_resp_header(conn, "content-type", type)

  defp refuse(stub, status, body) do
    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp capture_request(stub) do
    parent = self()

    Req.Test.stub(stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.request_path, conn.req_headers, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_resp(200, message_events("ok") <> completed())
    end)
  end

  defp attach_calls do
    test_pid = self()
    handler_id = "chatgpt-plan-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:fermix, :provider, :call],
      fn _event, measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:call, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "request contract" do
    test "the golden body: additional_tools first, store/stream/instructions, nothing forbidden" do
      stub = stub_id()
      capture_request(stub)

      assert {:ok, _turn} =
               ChatGPTPlan.chat(messages(), [capability()], opts(stub, reasoning_effort: :high))

      assert_receive {:request, "/v1/responses", headers, body}

      assert body == %{
               "model" => "gpt-6.1-sol",
               "instructions" => ModelOverlays.apply_codex("You are Fermix."),
               "store" => false,
               "stream" => true,
               "input" => [
                 %{
                   "type" => "additional_tools",
                   "role" => "developer",
                   "tools" => [
                     %{
                       "type" => "function",
                       "name" => "echo",
                       "description" => "Echo input back",
                       "parameters" => %{
                         "type" => "object",
                         "properties" => %{"text" => %{"type" => "string"}},
                         "required" => ["text"]
                       },
                       "strict" => false
                     }
                   ]
                 },
                 %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Hi"}]}
               ],
               "reasoning" => %{"effort" => "high", "summary" => "auto"},
               "include" => ["reasoning.encrypted_content"]
             }

      for field <- @forbidden, do: refute(Map.has_key?(body, field), "sent #{field}")

      assert {"authorization", "Bearer plan-token"} in headers
      assert {"accept", "text/event-stream"} in headers
      assert {"content-type", "application/json"} in headers
      assert Enum.count(headers, fn {name, _value} -> name == "authorization" end) == 1

      for {name, _value} <- headers do
        refute name in @foreign_headers, "sent #{name}"
      end
    end

    test "no effort sends no reasoning and no include; no tools sends no tools item" do
      stub = stub_id()
      capture_request(stub)

      assert {:ok, _turn} = ChatGPTPlan.chat(messages(), [], opts(stub))
      assert_receive {:request, _path, _headers, body}

      refute Map.has_key?(body, "reasoning")
      refute Map.has_key?(body, "include")
      assert [%{"role" => "user"}] = body["input"]
    end

    # OpenAI Codex keeps the Codex/GPT-5 behavior contract: appended at the end
    # of the instructions (the prefix stays cacheable), and present even when
    # the conversation carries no system message.
    test "the instructions end with the Codex behavior contract, even with no system message" do
      stub = stub_id()
      capture_request(stub)

      assert {:ok, _turn} =
               ChatGPTPlan.chat([%{role: "user", content: "Hi"}], [], opts(stub))

      assert_receive {:request, _path, _headers, body}
      assert body["instructions"] == ModelOverlays.apply_codex("You are a helpful AI assistant.")
      assert body["instructions"] =~ "<tool_discipline>"
    end

    test ":none effort omits reasoning" do
      body =
        ChatGPTPlan.request_body(%{model: "m", input: [], tools: []}, reasoning_effort: :none)

      refute Map.has_key?(body, :reasoning)
      refute Map.has_key?(body, :include)
    end

    test "continue/3 replays history inline with the tools item first and instructions again" do
      stub = stub_id()

      sse =
        event(%{
          "type" => "response.output_item.done",
          "output_index" => 0,
          "item" => %{
            "type" => "function_call",
            "id" => "fc_1",
            "call_id" => "call_1",
            "name" => "echo",
            "arguments" => ~s({"text":"yo"})
          }
        }) <> completed()

      stream(stub, sse)

      assert {:ok, turn} = ChatGPTPlan.chat(messages(), [capability()], opts(stub))
      assert [%{call_id: "call_1", name: "echo"}] = turn.tool_calls

      capture_request(stub)

      assert {:ok, _next} =
               ChatGPTPlan.continue(
                 turn.provider_state,
                 [%{call_id: "call_1", output: "yo"}],
                 opts(stub)
               )

      assert_receive {:request, _path, _headers, body}
      assert body["instructions"] == ModelOverlays.apply_codex("You are Fermix.")

      assert [
               %{"type" => "additional_tools"},
               %{"role" => "user"},
               %{"type" => "function_call", "call_id" => "call_1", "name" => "echo"} = call,
               %{"type" => "function_call_output", "call_id" => "call_1", "output" => "yo"}
             ] = body["input"]

      refute Map.has_key?(call, "id")
    end
  end

  describe "stream outcomes" do
    test "response.completed is a delivered turn, with usage and one provider call event" do
      attach_calls()
      stub = stub_id()
      stream(stub, message_events("Hello") <> completed())

      assert {:ok, turn} =
               ChatGPTPlan.chat(messages(), [], opts(stub, session_id: "main-1", agent: "main"))

      assert turn.content == "Hello"
      assert turn.usage.prompt_tokens == 11
      assert turn.usage.completion_tokens == 2

      assert_receive {:call, %{duration_ms: _}, metadata}
      assert metadata.provider == :openai_codex
      assert metadata.adapter == :chatgpt_plan
      assert metadata.auth_mode == :oauth
      assert metadata.status == :ok
      assert metadata.session_id == "main-1"
      assert metadata.terminal_event == "response.completed"
      refute_receive {:call, _m, _meta}, 50
    end

    test "SSE with no Content-Type is accepted" do
      stub = stub_id()
      stream(stub, message_events("Hi") <> completed(), nil)

      assert {:ok, %{content: "Hi"}} = ChatGPTPlan.chat(messages(), [], opts(stub))
    end

    test "a different Content-Type is refused, quoting the body" do
      stub = stub_id()
      stream(stub, ~s({"output":[]}), "application/json")

      assert {:error, {:provider_error, error}} = ChatGPTPlan.chat(messages(), [], opts(stub))
      assert error.code == "unexpected_content_type"
      assert error.message =~ "application/json"
      assert error.provider_words == ~s({"output":[]})
      assert error.stage == :before_response
    end

    test "stream deltas reach the stream callback" do
      stub = stub_id()
      parent = self()
      stream(stub, message_events("Hello") <> completed())

      callback = fn delta -> send(parent, {:delta, delta}) end

      assert {:ok, _turn} =
               ChatGPTPlan.chat(messages(), [], opts(stub, stream_callback: callback))

      assert_received {:delta, {:text_delta, "Hello"}}
    end

    for {code, kind} <- [
          {"subscription_sharing_usage_limit_exceeded", :quota},
          {"subscription_sharing_usage_unavailable", :provider_unavailable},
          {"subscription_sharing_user_unavailable", :provider_unavailable},
          {"subscription_sharing_user_not_eligible", :plan_not_eligible},
          {"subscription_sharing_unsupported_capability", :invalid_request},
          {"subscription_sharing_route_not_supported", :invalid_request},
          {"subscription_sharing_invalid_user", :auth}
        ] do
      test "response.failed with #{code} after text streamed is #{kind}, mid-stream" do
        stub = stub_id()
        stream(stub, message_events("partial") <> failed(unquote(code)))

        assert {:error, {:provider_error, error}} = ChatGPTPlan.chat(messages(), [], opts(stub))
        assert error.kind == unquote(kind)
        assert error.code == unquote(code)
        assert error.stage == :mid_stream
        assert error.provider == :openai_codex
        assert error.auth_mode == :oauth
        assert error.provider_words == "ChatGPT says #{unquote(code)}"
      end
    end

    test "response.failed keeps the param the route named" do
      stub = stub_id()

      stream(
        stub,
        failed("subscription_sharing_unsupported_capability", %{"param" => "tools[0]"})
      )

      assert {:error, {:provider_error, %{param: "tools[0]"}}} =
               ChatGPTPlan.chat(messages(), [], opts(stub))
    end

    test "response.incomplete is its own outcome, with the reason as the vendor's words" do
      attach_calls()
      stub = stub_id()

      sse =
        message_events("half") <>
          event(%{
            "type" => "response.incomplete",
            "response" => %{
              "status" => "incomplete",
              "incomplete_details" => %{"reason" => "content_filter"}
            }
          })

      stream(stub, sse)

      assert {:error, {:provider_error, error}} = ChatGPTPlan.chat(messages(), [], opts(stub))
      assert error.code == "response_incomplete"
      assert error.provider_words == "content_filter"
      assert error.stage == :mid_stream
      assert_receive {:call, _m, %{status: :error, terminal_event: "response.incomplete"}}
    end

    test "a stream error event is its own outcome, nested or flat" do
      attach_calls()

      for payload <- [
            %{"type" => "error", "code" => "subscription_sharing_usage_limit_exceeded"},
            %{
              "type" => "error",
              "error" => %{"code" => "subscription_sharing_usage_limit_exceeded"}
            }
          ] do
        stub = stub_id()
        stream(stub, message_events("x") <> event(payload))

        assert {:error, {:provider_error, error}} = ChatGPTPlan.chat(messages(), [], opts(stub))
        assert error.kind == :quota
        assert error.code == "subscription_sharing_usage_limit_exceeded"
        assert error.message =~ "stream error event"
        assert_receive {:call, _m, %{terminal_event: "error"}}
      end
    end

    test "a stream that ends before any terminal event is a closed transport mid-stream" do
      stub = stub_id()
      stream(stub, message_events("cut"))

      assert {:error, {:provider_transport_error, error}} =
               ChatGPTPlan.chat(messages(), [], opts(stub))

      assert error.kind == :transport_closed
      assert error.stage == :mid_stream
      assert error.message =~ "before response.completed"
    end

    test "an empty 200 is a closed transport before any response" do
      stub = stub_id()
      stream(stub, "")

      assert {:error, {:provider_transport_error, %{kind: :transport_closed, stage: stage}}} =
               ChatGPTPlan.chat(messages(), [], opts(stub))

      assert stage == :before_response
    end

    test "a completed response with no output item is an error, never an empty turn" do
      stub = stub_id()
      stream(stub, completed())

      assert {:error, {:provider_error, %{code: "empty_response"}}} =
               ChatGPTPlan.chat(messages(), [], opts(stub))
    end
  end

  describe "refusals before the stream" do
    test "a bare detail body is quoted as the vendor's words and never read as a code" do
      stub = stub_id()
      refuse(stub, 403, ~s({"detail":"Plan usage is not available in this region."}))

      assert {:error, {:provider_error, error}} = ChatGPTPlan.chat(messages(), [], opts(stub))
      assert error.code == nil
      assert error.status == 403
      assert error.provider_words == "Plan usage is not available in this region."
      assert error.stage == :before_response
    end

    test "a structured not-eligible refusal is plan_not_eligible" do
      stub = stub_id()

      refuse(
        stub,
        403,
        Jason.encode!(%{
          "error" => %{
            "code" => "subscription_sharing_user_not_eligible",
            "message" => "Not eligible."
          }
        })
      )

      assert {:error, {:provider_error, error}} = ChatGPTPlan.chat(messages(), [], opts(stub))
      assert error.kind == :plan_not_eligible
      assert error.provider_words == "Not eligible."
    end

    test "a 429 usage limit before the stream is quota" do
      stub = stub_id()

      refuse(
        stub,
        429,
        ~s({"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Limit."}})
      )

      assert {:error, {:provider_error, %{kind: :quota, stage: :before_response}}} =
               ChatGPTPlan.chat(messages(), [], opts(stub))
    end
  end

  describe "auth" do
    test "a 401 refreshes once, retries once, and emits one event" do
      attach_calls()
      stub = stub_id()

      Req.Test.stub(stub, fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer stale-token"] ->
            Plug.Conn.send_resp(conn, 401, ~s({"error":{"code":"invalid_token"}}))

          ["Bearer fresh-token"] ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
            |> Plug.Conn.send_resp(200, message_events("ok") <> completed())
        end
      end)

      assert {:ok, %{content: "ok"}} =
               ChatGPTPlan.chat(messages(), [], oauth_opts(stub, RefreshingTokenServer))

      assert_received :refreshed
      refute_received :refreshed
      assert_receive {:call, _m, %{status: :ok}}
      refute_receive {:call, _m, _meta}, 50
    end

    test "a 401 after the one refresh is an oauth auth error, with no second refresh" do
      stub = stub_id()
      parent = self()

      Req.Test.stub(stub, fn conn ->
        send(parent, :posted)

        Plug.Conn.send_resp(
          conn,
          401,
          ~s({"error":{"code":"subscription_sharing_invalid_user","message":"Invalid."}})
        )
      end)

      assert {:error, {:provider_error, error}} =
               ChatGPTPlan.chat(messages(), [], oauth_opts(stub, RefreshingTokenServer))

      assert error.kind == :auth
      assert error.status == 401
      assert error.auth_mode == :oauth
      assert_received :refreshed
      refute_received :refreshed
      assert_received :posted
      assert_received :posted
      refute_received :posted
    end

    test "a failed refresh keeps the first 401 and never posts again" do
      stub = stub_id()
      parent = self()

      Req.Test.stub(stub, fn conn ->
        send(parent, :posted)
        Plug.Conn.send_resp(conn, 401, ~s({"error":{"code":"invalid_token"}}))
      end)

      assert {:error, {:provider_error, %{kind: :auth, status: 401}}} =
               ChatGPTPlan.chat(messages(), [], oauth_opts(stub, RefusingTokenServer))

      assert_received :posted
      refute_received :posted
    end

    test "no credential at all is an oauth auth error before any request" do
      assert {:error, {:provider_error, %{kind: :auth, status: nil, auth_mode: :oauth}}} =
               ChatGPTPlan.chat(messages(), [], model: "gpt-6.1-sol")
    end
  end

  defp plan_error(kind, fields \\ %{}) do
    {:provider_error, Map.merge(%{provider: :openai_codex, kind: kind, code: nil}, fields)}
  end

  describe "refusal_sentence/1" do
    test "each §8 refusal has its own sentence" do
      assert ChatGPTPlan.refusal_sentence(
               plan_error(:quota, %{code: "subscription_sharing_usage_limit_exceeded"})
             ) == @usage_limit

      assert ChatGPTPlan.refusal_sentence(
               plan_error(:provider_unavailable, %{code: "subscription_sharing_usage_unavailable"})
             ) == "ChatGPT could not check your plan's usage right now. Try again shortly."

      assert ChatGPTPlan.refusal_sentence(
               plan_error(:plan_not_eligible, %{code: "subscription_sharing_user_not_eligible"})
             ) ==
               "This ChatGPT account or workspace can't use its plan in Fermix. " <>
                 "ChatGPT Plus and Pro plans can."

      assert ChatGPTPlan.refusal_sentence(
               plan_error(:plan_not_eligible, %{
                 code: "subscription_sharing_v2_client_not_enabled"
               })
             ) == "OpenAI has not enabled plan usage for Fermix's sign-in."

      assert ChatGPTPlan.refusal_sentence(
               plan_error(:invalid_request, %{
                 code: "subscription_sharing_unsupported_capability",
                 param: "truncation"
               })
             ) == "ChatGPT refused part of this request (`truncation`)."

      assert ChatGPTPlan.refusal_sentence(
               plan_error(:invalid_request, %{code: "subscription_sharing_route_not_supported"})
             ) == "ChatGPT plan usage does not cover this request type."

      assert ChatGPTPlan.refusal_sentence(plan_error(:auth, %{status: 401})) ==
               "Your ChatGPT connection needs to be renewed. Sign in again."
    end

    test "a usage limit names no reset time" do
      sentence =
        ChatGPTPlan.refusal_sentence(
          plan_error(:quota, %{code: "subscription_sharing_usage_limit_exceeded"})
        )

      refute sentence =~ "Try again in"
    end

    test "other errors and other providers have none" do
      assert ChatGPTPlan.refusal_sentence(plan_error(:rate_limit)) == nil
      assert ChatGPTPlan.refusal_sentence(plan_error(:auth, %{status: 403})) == nil

      assert ChatGPTPlan.refusal_sentence(
               {:provider_error, %{provider: :openai, kind: :quota, code: nil}}
             ) == nil

      assert ChatGPTPlan.refusal_sentence(:context_length_exceeded) == nil
    end
  end

  test "supports_streaming? is true" do
    assert ChatGPTPlan.supports_streaming?()
  end
end
