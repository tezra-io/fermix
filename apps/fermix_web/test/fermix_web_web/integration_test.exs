defmodule FermixWebWeb.IntegrationTest do
  @moduledoc """
  End-to-end integration tests: Telegram webhook → MainAgent → AgentLoop → response.

  Uses a mock provider to avoid real API calls while testing the full pipeline.
  """

  use FermixWebWeb.ConnCase

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Capabilities.Builtin, as: BuiltinCapability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore

  @moduletag :integration

  defmodule MockProvider do
    @moduledoc false
    @behaviour FermixCore.Providers.Provider
    @behaviour FermixCore.Providers.Adapter

    @impl FermixCore.Providers.Provider
    def chat(_messages, _opts), do: {:ok, response()}

    @impl FermixCore.Providers.Provider
    def models, do: {:ok, ["mock-model"]}

    @impl FermixCore.Providers.Adapter
    def chat(_messages, _capabilities, _opts), do: {:ok, turn()}

    @impl FermixCore.Providers.Adapter
    def continue(_provider_state, _tool_results, _opts), do: {:ok, turn()}

    @impl FermixCore.Providers.Adapter
    def to_provider_tools(capabilities), do: capabilities

    @impl FermixCore.Providers.Adapter
    def parse_tool_calls(_response), do: []

    @impl FermixCore.Providers.Adapter
    def parse_response(response), do: response

    @impl FermixCore.Providers.Adapter
    def supports_streaming?, do: false

    defp response do
      %{
        content: "Hello from the integration test!",
        tool_calls: [],
        usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15},
        model: "mock-model"
      }
    end

    defp turn do
      %{
        content: "Hello from the integration test!",
        tool_calls: [],
        provider_state: %{},
        usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15},
        model: "mock-model"
      }
    end
  end

  defmodule ToolCallProvider do
    @moduledoc false
    @behaviour FermixCore.Providers.Provider
    @behaviour FermixCore.Providers.Adapter

    @impl FermixCore.Providers.Provider
    def chat(messages, _opts) do
      has_tool_result = Enum.any?(messages, &(&1.role == "tool" || &1[:role] == "tool"))
      {:ok, legacy_response(has_tool_result)}
    end

    @impl FermixCore.Providers.Provider
    def models, do: {:ok, ["mock-model"]}

    @impl FermixCore.Providers.Adapter
    def chat(_messages, capabilities, _opts) do
      {:ok, turn(initial_tool_calls(), capabilities)}
    end

    @impl FermixCore.Providers.Adapter
    def continue(provider_state, _tool_results, _opts) do
      capabilities = Map.get(provider_state, :capabilities, [])

      turn = %{
        content: "The command output was captured.",
        tool_calls: [],
        provider_state: %{capabilities: capabilities},
        usage: %{prompt_tokens: 20, completion_tokens: 10, total_tokens: 30},
        model: "mock-model"
      }

      {:ok, turn}
    end

    @impl FermixCore.Providers.Adapter
    def to_provider_tools(capabilities), do: capabilities

    @impl FermixCore.Providers.Adapter
    def parse_tool_calls(_response), do: []

    @impl FermixCore.Providers.Adapter
    def parse_response(response), do: response

    @impl FermixCore.Providers.Adapter
    def supports_streaming?, do: false

    defp initial_tool_calls do
      [
        %{
          id: "call_1",
          call_id: "call_1",
          name: "shell",
          arguments: Jason.encode!(%{"command" => "echo integration-test"})
        }
      ]
    end

    defp turn(tool_calls, capabilities) do
      %{
        content: "",
        tool_calls: tool_calls,
        provider_state: %{capabilities: capabilities},
        usage: %{prompt_tokens: 15, completion_tokens: 8, total_tokens: 23},
        model: "mock-model"
      }
    end

    defp legacy_response(true) do
      %{
        content: "The command output was captured.",
        tool_calls: [],
        usage: %{prompt_tokens: 20, completion_tokens: 10, total_tokens: 30},
        model: "mock-model"
      }
    end

    defp legacy_response(false) do
      %{
        content: "",
        tool_calls: [
          %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{
              "name" => "shell",
              "arguments" => Jason.encode!(%{"command" => "echo integration-test"})
            }
          }
        ],
        usage: %{prompt_tokens: 15, completion_tokens: 8, total_tokens: 23},
        model: "mock-model"
      }
    end
  end

  setup do
    Application.put_env(:fermix_channels, :telegram, bot_token: "test_bot_token")

    # Start test-scoped GenServers
    conversation_store =
      start_supervised!({ConversationStore, [name: :"cs_integration_#{System.unique_integer()}"]})

    capability_registry =
      start_supervised!(
        {CapabilityRegistry, [name: :"caps_integration_#{System.unique_integer()}"]}
      )

    on_exit(fn ->
      Application.delete_env(:fermix_channels, :telegram)
    end)

    {:ok, conversation_store: conversation_store, capability_registry: capability_registry}
  end

  describe "full pipeline: webhook → agent → response" do
    test "simple message gets agent response", %{
      conversation_store: cs,
      capability_registry: caps
    } do
      test_pid = self()

      agent =
        start_supervised!(
          {MainAgent,
           [
             name: :"agent_integration_#{System.unique_integer()}",
             provider: MockProvider,
             capability_registry: caps,
             conversation_store: cs
           ]}
        )

      # Build a message that goes through the full pipeline
      msg = %{
        content: "Hello, agent!",
        sender: "test_user",
        channel: "telegram",
        chat_id: "42",
        reply_fn: fn response -> send(test_pid, {:reply, reply_payload(response)}) end
      }

      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, "Hello from the integration test!"}, 5_000

      # Verify conversation was stored
      history = ConversationStore.get_history({"telegram", "42", :root}, server: cs)
      assert length(history) == 2

      roles = Enum.map(history, & &1.role)
      assert roles == ["user", "assistant"]
    end

    test "message with tool call executes tool and responds", %{
      conversation_store: cs,
      capability_registry: caps
    } do
      test_pid = self()

      # Register shell as a built-in capability
      :ok =
        CapabilityRegistry.register(
          caps,
          BuiltinCapability.from_tool_module(FermixCore.Tools.Shell)
        )

      agent =
        start_supervised!(
          {MainAgent,
           [
             name: :"agent_tool_#{System.unique_integer()}",
             provider: ToolCallProvider,
             capability_registry: caps,
             conversation_store: cs
           ]}
        )

      msg = %{
        content: "Run echo",
        sender: "test_user",
        channel: "telegram",
        chat_id: "99",
        reply_fn: fn response -> send(test_pid, {:reply, reply_payload(response)}) end
      }

      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, "The command output was captured."}, 10_000

      history = ConversationStore.get_history({"telegram", "99", :root}, server: cs)
      assert length(history) == 2
    end

    test "telegram webhook route is removed (polling only)", %{
      conn: conn,
      conversation_store: _cs,
      capability_registry: _caps
    } do
      payload = %{
        "update_id" => 123_456,
        "message" => %{
          "message_id" => 789,
          "chat" => %{"id" => 42},
          "from" => %{"username" => "test_user", "first_name" => "Test"},
          "text" => "hello from e2e"
        }
      }

      conn = post(conn, "/webhook/telegram", payload)

      assert conn.status == 404
    end
  end

  defp reply_payload({:text, text}), do: text
  defp reply_payload(response), do: response
end
