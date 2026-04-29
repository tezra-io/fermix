defmodule FermixCore.Providers.OpenAI.CodexTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Providers.OpenAI.Codex

  defmodule StubTokenServer do
    @moduledoc false
    use GenServer

    def init(reply), do: {:ok, reply}
    def handle_call(:get_token, _from, reply), do: {:reply, reply, reply}
  end

  defp capability do
    Capability.new(%{
      name: "echo",
      description: "Echo input back",
      parameters: %{type: "object", properties: %{text: %{type: "string"}}, required: ["text"]},
      kind: :builtin,
      executor: {Kernel, :inspect, []}
    })
  end

  describe "to_provider_tools/1" do
    test "always returns [] — Codex does not support tool calls" do
      assert Codex.to_provider_tools([capability()]) == []
      assert Codex.to_provider_tools([]) == []
    end
  end

  describe "continue/3" do
    test "returns {:error, :tool_calls_not_supported_on_codex}" do
      assert Codex.continue(%{}, [], []) == {:error, :tool_calls_not_supported_on_codex}
    end
  end

  describe "supports_streaming?/0" do
    test "returns true" do
      assert Codex.supports_streaming?()
    end
  end

  describe "chat/3" do
    test "posts SSE-streaming body to Codex URL with bearer token" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "gpt-5"
        assert decoded["stream"] == true
        assert decoded["store"] == false
        assert is_list(decoded["input"])

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
        Codex.chat(messages, [],
          access_token: "header.eyJzdWIiOiJ1c3JfMSJ9.sig",
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert turn.content == "hello world"
      assert turn.tool_calls == []
      assert turn.usage.prompt_tokens == 3
      assert turn.usage.completion_tokens == 2
      assert turn.usage.total_tokens == 5
      assert turn.model == "gpt-5"
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
          access_token: "header.eyJzdWIiOiJ1c3JfMSJ9.sig",
          model: "gpt-5",
          base_url: "https://chatgpt.test/codex/responses",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert message == "Codex API error: 401"
    end
  end
end
