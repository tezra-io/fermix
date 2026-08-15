defmodule FermixCore.Providers.XAI.ResponsesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Providers.XAI.Responses

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

  defp enum_capability do
    Capability.new(%{
      name: "pick_model",
      description: "Pick a model id.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "model" => %{
            "type" => "string",
            "enum" => ["meta/llama-3", "openai/gpt-4o"]
          },
          "mode" => %{"type" => "string", "enum" => ["fast", "slow"]}
        }
      },
      kind: :mcp,
      policy_class: :read_only,
      executor: {Kernel, :inspect, []}
    })
  end

  defp text_response_body do
    %{
      "model" => "grok-4.3",
      "output" => [
        %{
          "type" => "message",
          "id" => "msg_1",
          "content" => [%{"type" => "output_text", "text" => "Hello from Grok"}]
        }
      ],
      "usage" => %{"input_tokens" => 9, "output_tokens" => 3}
    }
  end

  defp function_call_response_body do
    %{
      "model" => "grok-4.3",
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

  defp chat_opts(extra \\ []) do
    Keyword.merge(
      [
        api_key: "xai-test-key",
        model: "grok-4.3",
        base_url: "https://api.x.ai/v1",
        req_options: [plug: {Req.Test, __MODULE__}]
      ],
      extra
    )
  end

  describe "chat/3 — request shape" do
    test "posts bearer auth to /responses with store false and parallel tool calls" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert ["Bearer xai-test-key"] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.request_path == "/v1/responses"
        assert decoded["model"] == "grok-4.3"
        assert decoded["store"] == false
        assert decoded["parallel_tool_calls"] == true
        assert decoded["instructions"] == "You are helpful"
        assert [%{"role" => "user"}] = decoded["input"]
        assert [%{"name" => "echo", "type" => "function"}] = decoded["tools"]

        Req.Test.json(conn, text_response_body())
      end)

      messages = [
        %{role: "system", content: "You are helpful"},
        %{role: "user", content: "Hi"}
      ]

      assert {:ok, turn} = Responses.chat(messages, [capability()], chat_opts())
      assert turn.content == "Hello from Grok"
      assert turn.usage == %{prompt_tokens: 9, completion_tokens: 3, total_tokens: 12}
    end

    test "includes reasoning effort for models that accept it and clamps above the ceiling" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        # :max is above xAI's :xhigh ceiling and clamps to it. The per-MODEL
        # narrowing (only Grok 4.6 accepts xhigh) happens at route resolution
        # via ModelCatalog.clamp_effort/3 — this edge knows only the provider
        # vocabulary, so it must not be asserted here.
        assert Jason.decode!(body)["reasoning"] == %{"effort" => "xhigh"}
        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} =
               Responses.chat(
                 [%{role: "user", content: "hi"}],
                 [],
                 chat_opts(reasoning_effort: :max)
               )
    end

    test "omits reasoning for :none and for models that reject reasoning.effort" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        refute Map.has_key?(Jason.decode!(body), "reasoning")
        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} =
               Responses.chat(
                 [%{role: "user", content: "hi"}],
                 [],
                 chat_opts(reasoning_effort: :none)
               )

      assert {:ok, _turn} =
               Responses.chat(
                 [%{role: "user", content: "hi"}],
                 [],
                 chat_opts(model: "grok-code-fast-1", reasoning_effort: :high)
               )
    end

    test "sanitizes slash-containing enum values from tool schemas" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [tool] = Jason.decode!(body)["tools"]

        properties = tool["parameters"]["properties"]
        # All slash values removed; empty enum key dropped entirely.
        refute Map.has_key?(properties["model"], "enum")
        assert properties["mode"]["enum"] == ["fast", "slow"]

        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} =
               Responses.chat([%{role: "user", content: "go"}], [enum_capability()], chat_opts())
    end

    test "returns an auth error without a credential" do
      assert {:error, {:provider_error, %{provider: :xai, kind: :auth, message: message}}} =
               Responses.chat([%{role: "user", content: "x"}], [], model: "grok-4.3")

      assert message =~ ":api_key"
    end
  end

  describe "chat/3 — responses and errors" do
    test "normalizes function calls through the shared Responses parser" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, function_call_response_body())
      end)

      assert {:ok, turn} =
               Responses.chat([%{role: "user", content: "go"}], [capability()], chat_opts())

      assert [%{name: "echo", call_id: "call_xyz"}] = turn.tool_calls
    end

    test "continue/3 replays prior input plus function_call_output items" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})
        Req.Test.json(conn, text_response_body())
      end)

      {:ok, turn1} =
        Responses.chat([%{role: "user", content: "go"}], [capability()], chat_opts())

      assert_receive {:request_body, _first}

      {:ok, _turn2} =
        Responses.continue(
          turn1.provider_state,
          [%{call_id: "call_xyz", output: "result-1"}],
          chat_opts()
        )

      assert_receive {:request_body, second}

      types = Enum.map(second["input"], & &1["type"])
      assert "function_call_output" in types
    end

    test "provider errors say :xai, never :openai" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          429,
          Jason.encode!(%{"error" => %{"code" => "rate_limit", "message" => "slow down"}})
        )
      end)

      assert {:error, {:provider_error, error}} =
               Responses.chat([%{role: "user", content: "x"}], [], chat_opts())

      assert error.provider == :xai
      assert error.adapter == :responses
      assert error.kind == :rate_limit
    end

    test "context-window errors return bare :context_length_exceeded" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          400,
          Jason.encode!(%{
            "error" => %{"code" => "context_length_exceeded", "message" => "too long"}
          })
        )
      end)

      assert {:error, :context_length_exceeded} =
               Responses.chat([%{role: "user", content: "x"}], [], chat_opts())
    end
  end

  describe "chat/3 — telemetry" do
    test "emits provider :xai with auth_mode and correlation ids" do
      test_pid = self()
      handler_id = "xai-call-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn event, measurements, metadata, _config ->
          if self() == test_pid do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} =
               Responses.chat(
                 [%{role: "user", content: "hi"}],
                 [capability()],
                 chat_opts(session_id: "main-9", parent_session: "root-2")
               )

      assert_receive {:telemetry, [:fermix, :provider, :call], measurements,
                      %{provider: :xai} = metadata}

      assert measurements.duration_ms >= 0
      assert metadata.adapter == :responses
      assert metadata.auth_mode == :api_key
      assert metadata.model == "grok-4.3"
      assert metadata.status == :ok
      assert metadata.tokens == %{prompt: 9, completion: 3}
      assert metadata.session_id == "main-9"
      assert metadata.parent_session == "root-2"
    end
  end

  describe "supports_streaming?/0" do
    test "is false" do
      refute Responses.supports_streaming?()
    end
  end

  # Stateless token-server stubs — the 401-retry test distinguishes stale
  # vs fresh bearers by header (same pattern as the Anthropic adapter tests).
  defmodule RefreshingTokenServer do
    def get_token("prof-retry"), do: {:ok, "stale-token"}
    def refresh("prof-retry"), do: {:ok, "fresh-token"}
  end

  defmodule RefusingTokenServer do
    def get_token("prof-dead"), do: {:ok, "dead-token"}
    def refresh("prof-dead"), do: {:error, :reauthorization_required}
  end

  defp oauth_opts(extra \\ []) do
    Keyword.merge(
      [
        token_server: RefreshingTokenServer,
        auth_profile: "prof-retry",
        model: "grok-4.3",
        base_url: "https://api.x.ai/v1",
        req_options: [plug: {Req.Test, __MODULE__}]
      ],
      extra
    )
  end

  describe "chat/3 — OAuth mode" do
    test "fetches the bearer through the token server and tags telemetry with oauth" do
      test_pid = self()
      handler_id = "xai-oauth-call-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn event, measurements, metadata, _config ->
          if self() == test_pid do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        assert ["Bearer stale-token"] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} = Responses.chat([%{role: "user", content: "hi"}], [], oauth_opts())

      assert_receive {:telemetry, [:fermix, :provider, :call], _measurements,
                      %{provider: :xai, auth_mode: :oauth} = metadata}

      assert metadata.status == :ok
    end

    test "a 401 refreshes through the token server, retries once, and emits one event" do
      test_pid = self()
      handler_id = "xai-retry-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn event, measurements, metadata, _config ->
          if self() == test_pid do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
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
              Jason.encode!(%{"error" => %{"code" => "unauthorized", "message" => "expired"}})
            )

          ["Bearer fresh-token"] ->
            Req.Test.json(conn, text_response_body())
        end
      end)

      assert {:ok, turn} = Responses.chat([%{role: "user", content: "hi"}], [], oauth_opts())
      assert turn.content == "Hello from Grok"

      assert_receive {:telemetry, [:fermix, :provider, :call], _measurements,
                      %{provider: :xai, auth_mode: :oauth, status: :ok}}

      # One emit per logical call — no phantom error event for the
      # refreshed 401 (Codex precedent).
      refute_receive {:telemetry, [:fermix, :provider, :call], _m,
                      %{provider: :xai, error_status: 401}},
                     100
    end

    test "permanent refresh failure surfaces the original auth error tagged with oauth" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          401,
          Jason.encode!(%{"error" => %{"code" => "unauthorized", "message" => "expired"}})
        )
      end)

      assert {:error, {:provider_error, error}} =
               Responses.chat(
                 [%{role: "user", content: "hi"}],
                 [],
                 oauth_opts(token_server: RefusingTokenServer, auth_profile: "prof-dead")
               )

      assert error.kind == :auth
      assert error.status == 401
      assert error.auth_mode == :oauth
    end

    test "an explicit access_token posts a bearer without touching the token server" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert ["Bearer static-token"] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, text_response_body())
      end)

      assert {:ok, _turn} =
               Responses.chat(
                 [%{role: "user", content: "hi"}],
                 [],
                 oauth_opts(access_token: "static-token", token_server: nil, auth_profile: nil)
               )
    end
  end
end
