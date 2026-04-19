defmodule FermixWebWeb.IntegrationTest do
  @moduledoc """
  End-to-end integration tests: Telegram webhook → MainAgent → AgentLoop → response.

  Uses a mock provider to avoid real API calls while testing the full pipeline.
  """

  use FermixWebWeb.ConnCase

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Tools.Registry

  @moduletag :integration

  defmodule MockProvider do
    @moduledoc false
    @behaviour FermixCore.Providers.Provider

    @impl true
    def chat(_messages, _opts) do
      {:ok,
       %{
         content: "Hello from the integration test!",
         tool_calls: [],
         usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15},
         model: "mock-model"
       }}
    end

    @impl true
    def models, do: {:ok, ["mock-model"]}
  end

  defmodule ToolCallProvider do
    @moduledoc false
    @behaviour FermixCore.Providers.Provider

    @impl true
    def chat(messages, _opts) do
      has_tool_result = Enum.any?(messages, &(&1.role == "tool" || &1[:role] == "tool"))

      if has_tool_result do
        {:ok,
         %{
           content: "The command output was captured.",
           tool_calls: [],
           usage: %{prompt_tokens: 20, completion_tokens: 10, total_tokens: 30},
           model: "mock-model"
         }}
      else
        {:ok,
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
         }}
      end
    end

    @impl true
    def models, do: {:ok, ["mock-model"]}
  end

  setup do
    Application.put_env(:fermix_channels, :telegram, bot_token: "test_bot_token")

    # Start test-scoped GenServers
    conversation_store =
      start_supervised!({ConversationStore, [name: :"cs_integration_#{System.unique_integer()}"]})

    registry =
      start_supervised!({Registry, [name: :"reg_integration_#{System.unique_integer()}"]})

    on_exit(fn ->
      Application.delete_env(:fermix_channels, :telegram)
    end)

    {:ok, conversation_store: conversation_store, registry: registry}
  end

  describe "full pipeline: webhook → agent → response" do
    test "simple message gets agent response", %{
      conversation_store: cs,
      registry: reg
    } do
      test_pid = self()

      agent =
        start_supervised!(
          {MainAgent,
           [
             name: :"agent_integration_#{System.unique_integer()}",
             provider: MockProvider,
             registry: reg,
             conversation_store: cs
           ]}
        )

      # Build a message that goes through the full pipeline
      msg = %{
        content: "Hello, agent!",
        sender: "test_user",
        channel: "telegram",
        chat_id: "42",
        reply_fn: fn response -> send(test_pid, {:reply, response}) end
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
      registry: reg
    } do
      test_pid = self()

      # Register shell tool
      Registry.register(reg, FermixCore.Tools.Shell)

      agent =
        start_supervised!(
          {MainAgent,
           [
             name: :"agent_tool_#{System.unique_integer()}",
             provider: ToolCallProvider,
             registry: reg,
             conversation_store: cs
           ]}
        )

      msg = %{
        content: "Run echo",
        sender: "test_user",
        channel: "telegram",
        chat_id: "99",
        reply_fn: fn response -> send(test_pid, {:reply, response}) end
      }

      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, "The command output was captured."}, 10_000

      history = ConversationStore.get_history({"telegram", "99", :root}, server: cs)
      assert length(history) == 2
    end

    test "telegram webhook route is removed (polling only)", %{
      conn: conn,
      conversation_store: _cs,
      registry: _reg
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

      conn = post(conn, ~p"/webhook/telegram", payload)

      assert conn.status == 404
    end
  end
end
