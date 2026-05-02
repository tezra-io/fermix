defmodule FermixCore.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.OpenAI

  # -- helpers --

  defp success_body(content, opts \\ []) do
    tool_calls = Keyword.get(opts, :tool_calls, [])
    model = Keyword.get(opts, :model, "gpt-5.4-mini")

    %{
      "choices" => [
        %{
          "message" => %{"content" => content, "tool_calls" => tool_calls},
          "model" => model
        }
      ],
      "usage" => %{
        "prompt_tokens" => 10,
        "completion_tokens" => 20,
        "total_tokens" => 30
      }
    }
  end

  defp stub_openai(test_pid, status, body) do
    Req.Test.stub(:openai, fn conn ->
      {:ok, req_body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(req_body)
      send(test_pid, {:openai_request, decoded})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp chat(messages, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:req_options, plug: {Req.Test, :openai})
      |> Keyword.put_new(:api_key, "test-key")
      |> Keyword.put_new(:auth_mode, :api_key)

    OpenAI.chat(messages, opts)
  end

  # -- models/0 --

  describe "models/0" do
    test "returns a list of model names" do
      assert {:ok, models} = OpenAI.models()
      assert is_list(models)
      assert "gpt-5.4" in models
      assert "gpt-5.4" in models
      assert Enum.all?(models, &is_binary/1)
    end
  end

  # -- chat/2: message formatting --

  describe "chat/2 message formatting" do
    test "sends messages with role and content" do
      stub_openai(self(), 200, success_body("Hello!"))
      messages = [%{role: "user", content: "Hi"}]

      {:ok, _resp} = chat(messages)

      assert_received {:openai_request, body}
      [msg] = body["messages"]
      assert msg["role"] == "user"
      assert msg["content"] == "Hi"
    end

    test "preserves multiple leading system messages for Chat Completions" do
      stub_openai(self(), 200, success_body("Hello!"))

      messages = [
        %{role: "system", content: "SOUL bootstrap"},
        %{role: "system", content: "AGENTS bootstrap"},
        %{role: "user", content: "Hi"}
      ]

      {:ok, _resp} = chat(messages)

      assert_received {:openai_request, body}

      assert Enum.map(body["messages"], & &1["role"]) == ["system", "system", "user"]

      assert Enum.map(body["messages"], & &1["content"]) == [
               "SOUL bootstrap",
               "AGENTS bootstrap",
               "Hi"
             ]
    end

    test "preserves tool_call_id on tool-result messages" do
      stub_openai(self(), 200, success_body("Done"))

      messages = [
        %{role: "tool", content: "result", tool_call_id: "call_123"}
      ]

      {:ok, _resp} = chat(messages)

      assert_received {:openai_request, body}
      [msg] = body["messages"]
      assert msg["tool_call_id"] == "call_123"
    end

    test "preserves tool_calls on assistant messages" do
      stub_openai(self(), 200, success_body("ok"))

      tc = [
        %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{"name" => "f", "arguments" => "{}"}
        }
      ]

      messages = [%{role: "assistant", content: "let me call", tool_calls: tc}]

      {:ok, _resp} = chat(messages)

      assert_received {:openai_request, body}
      [msg] = body["messages"]
      assert msg["tool_calls"] == tc
    end

    test "uses default model gpt-5.4-mini" do
      stub_openai(self(), 200, success_body("hi"))

      {:ok, _resp} = chat([%{role: "user", content: "hi"}])

      assert_received {:openai_request, body}
      assert body["model"] == "gpt-5.4-mini"
    end

    test "passes response_format through for schema-constrained extraction" do
      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "memory_candidates",
          strict: true,
          schema: %{type: "object", required: ["candidates"]}
        }
      }

      stub_openai(self(), 200, success_body(~s({"candidates":[]})))

      {:ok, _resp} =
        chat([%{role: "user", content: "hi"}], response_format: response_format)

      assert_received {:openai_request, body}
      assert body["response_format"]["type"] == "json_schema"
      assert body["response_format"]["json_schema"]["strict"] == true
      assert body["response_format"]["json_schema"]["schema"]["required"] == ["candidates"]
    end

    test "respects model option" do
      stub_openai(self(), 200, success_body("hi"))

      {:ok, _resp} = chat([%{role: "user", content: "hi"}], model: "gpt-4o")

      assert_received {:openai_request, body}
      assert body["model"] == "gpt-4o"
    end

    test "sends temperature" do
      stub_openai(self(), 200, success_body("hi"))

      {:ok, _resp} = chat([%{role: "user", content: "hi"}], temperature: 0.2)

      assert_received {:openai_request, body}
      assert body["temperature"] == 0.2
    end
  end

  # -- chat/2: tool definitions --

  describe "chat/2 tool definitions" do
    test "includes tools in request body when provided" do
      stub_openai(self(), 200, success_body("ok"))

      tools = [
        %{
          type: "function",
          function: %{
            name: "get_weather",
            description: "Get weather",
            parameters: %{type: "object"}
          }
        }
      ]

      {:ok, _resp} = chat([%{role: "user", content: "weather?"}], tools: tools)

      assert_received {:openai_request, body}
      assert is_list(body["tools"])
      assert length(body["tools"]) == 1
    end

    test "omits tools key when tools not provided" do
      stub_openai(self(), 200, success_body("hi"))

      {:ok, _resp} = chat([%{role: "user", content: "hi"}])

      assert_received {:openai_request, body}
      refute Map.has_key?(body, "tools")
    end
  end

  # -- chat/2: response parsing --

  describe "chat/2 response parsing" do
    test "parses content and usage from success response" do
      stub_openai(self(), 200, success_body("Hello!"))

      assert {:ok, resp} = chat([%{role: "user", content: "hi"}])
      assert resp.content == "Hello!"
      assert resp.usage.prompt_tokens == 10
      assert resp.usage.completion_tokens == 20
      assert resp.usage.total_tokens == 30
    end

    test "parses tool_calls from response" do
      tool_calls = [
        %{
          "id" => "call_abc",
          "type" => "function",
          "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"NYC"})}
        }
      ]

      stub_openai(self(), 200, success_body("", tool_calls: tool_calls))

      assert {:ok, resp} = chat([%{role: "user", content: "weather?"}])
      assert [tc] = resp.tool_calls
      assert tc["id"] == "call_abc"
      assert tc["function"]["name"] == "get_weather"
    end

    test "returns empty content when null in response" do
      body = %{
        "choices" => [%{"message" => %{"content" => nil}, "model" => "gpt-5.4-mini"}],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2, "total_tokens" => 3}
      }

      stub_openai(self(), 200, body)

      assert {:ok, resp} = chat([%{role: "user", content: "hi"}])
      assert resp.content == ""
    end

    test "returns model from response" do
      stub_openai(self(), 200, success_body("hi", model: "gpt-4o"))

      assert {:ok, resp} = chat([%{role: "user", content: "hi"}])
      assert resp.model == "gpt-4o"
    end
  end

  # -- chat/2: error handling --

  describe "chat/2 error handling" do
    test "returns error on non-200 status" do
      error_body = %{"error" => %{"message" => "Rate limit exceeded"}}
      stub_openai(self(), 429, error_body)

      assert {:error, msg} = chat([%{role: "user", content: "hi"}])
      assert msg =~ "429"
    end

    test "returns error on malformed response (missing choices)" do
      stub_openai(self(), 200, %{"unexpected" => "shape"})

      assert {:error, _reason} = chat([%{role: "user", content: "hi"}])
    end

    test "returns error on connection failure" do
      Req.Test.stub(:openai, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _reason} =
               chat([%{role: "user", content: "hi"}])
    end
  end

  # -- chat/2: telemetry --

  describe "chat/2 telemetry" do
    test "emits [:fermix, :provider, :call] on success" do
      _ref =
        :telemetry.attach(
          "test-provider-success",
          [:fermix, :provider, :call],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      stub_openai(self(), 200, success_body("hi"))
      {:ok, _} = chat([%{role: "user", content: "hi"}])

      assert_received {:telemetry, [:fermix, :provider, :call], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.provider == :openai
      assert metadata.model == "gpt-5.4-mini"
      assert metadata.status == :ok
      assert is_map(metadata.tokens)

      :telemetry.detach("test-provider-success")
    after
      :telemetry.detach("test-provider-success")
    end

    test "emits [:fermix, :provider, :call] on error" do
      _ref =
        :telemetry.attach(
          "test-provider-error",
          [:fermix, :provider, :call],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      stub_openai(self(), 500, %{"error" => "boom"})
      {:error, _} = chat([%{role: "user", content: "hi"}])

      assert_received {:telemetry, [:fermix, :provider, :call], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.provider == :openai
      assert metadata.status == :error

      :telemetry.detach("test-provider-error")
    after
      :telemetry.detach("test-provider-error")
    end
  end

  # -- chat/2: auth mode --

  describe "chat/2 auth mode" do
    test "rejects OAuth on the regular OpenAI provider" do
      assert {:error, {:unsupported_auth_mode, :oauth}} =
               OpenAI.chat(
                 [%{role: "user", content: "hi"}],
                 auth_mode: :oauth,
                 req_options: [plug: {Req.Test, :openai}]
               )
    end

    test "defaults to :api_key mode" do
      stub_openai(self(), 200, success_body("default mode"))

      assert {:ok, resp} = chat([%{role: "user", content: "hi"}])
      assert resp.content == "default mode"
    end
  end

  # -- chat/2: config --

  describe "chat/2 config" do
    test "sends authorization header with api_key" do
      Req.Test.stub(:openai, fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        send(self(), {:auth_header, auth})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(success_body("hi")))
      end)

      {:ok, _resp} = chat([%{role: "user", content: "hi"}], api_key: "sk-my-key")

      assert_received {:auth_header, "Bearer sk-my-key"}
    end
  end
end
