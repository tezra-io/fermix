defmodule FermixCore.Agents.TurnRunnerUltraTest do
  @moduledoc """
  `/ultra` is now a run-mode of the normal turn (Option B, design
  ADAPTIVE_EFFORT_AND_DELEGATION §6): a message tagged `run_profile: :ultra`
  runs the ordinary agent loop with `subagent_mode: :ultra` in context and an
  exhaustive-mode addendum prepended to the system prompt — NOT a separate
  orchestrator. An untagged message takes the same loop without either.
  """
  use ExUnit.Case, async: false

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Builtin, as: BuiltinCapability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Tools.Subagents

  # Captures the messages AND capabilities it is handed so the test can assert
  # both the ultra addendum injection and that the ultra context reached the
  # loop's tool-schema refresh (the model sees the wide subagents caps).
  defmodule CapturingAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, capabilities, _opts) do
      send(
        Application.fetch_env!(:fermix_core, :ultra_test_pid),
        {:chat, messages, capabilities}
      )

      {:ok,
       %{
         content: "normal-loop-answer",
         tool_calls: [],
         provider_state: %{},
         usage: %{prompt_tokens: 10, completion_tokens: 1, total_tokens: 11},
         model: "mock-model"
       }}
    end

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, :unexpected_continue}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  setup do
    prior_pid = Application.get_env(:fermix_core, :ultra_test_pid)
    Application.put_env(:fermix_core, :ultra_test_pid, self())

    on_exit(fn ->
      case prior_pid do
        nil -> Application.delete_env(:fermix_core, :ultra_test_pid)
        value -> Application.put_env(:fermix_core, :ultra_test_pid, value)
      end
    end)

    :ok
  end

  describe "run/3 with run_profile: :ultra" do
    test "runs the normal loop and prepends the exhaustive-mode addendum as a leading system message" do
      turn_state = build_turn_state()

      msg = %{
        channel: "telegram",
        chat_id: "ultra_turn",
        sender: "user",
        content: "plan a complex trip",
        source_trust: :operator,
        metadata: %{run_profile: :ultra}
      }

      assert {:ok, "normal-loop-answer", _} = TurnRunner.run(msg, turn_state, fn _ -> :ok end)

      assert_receive {:chat, messages, _capabilities}, 5_000

      # System messages still lead (Anthropic adapter requires it); the addendum
      # is the LAST leading system message, before the user turn.
      {system_run, rest} = Enum.split_while(messages, &(&1.role == "system"))
      assert List.last(system_run).content =~ "Exhaustive mode (/ultra)"
      assert List.last(system_run).content =~ "fan out WIDE with the `subagents` tool"
      assert [%{role: "user", content: "plan a complex trip"}] = rest
    end

    test "carries subagent_mode: :ultra into the loop, widening the subagents tool schema" do
      turn_state = build_turn_state()

      msg = %{
        channel: "telegram",
        chat_id: "ultra_schema",
        sender: "user",
        content: "research this exhaustively",
        source_trust: :operator,
        metadata: %{run_profile: :ultra}
      }

      assert {:ok, "normal-loop-answer", _} = TurnRunner.run(msg, turn_state, fn _ -> :ok end)

      assert_receive {:chat, _messages, capabilities}, 5_000

      subagents = Enum.find(capabilities, &(&1.name == "subagents"))
      assert subagents, "expected the subagents capability in the operator profile"
      # Ultra widens the advertised caps (§4 / §6): 50 tasks, concurrency 12.
      assert subagents.parameters.properties.tasks.maxItems == 50
      assert subagents.parameters.properties.max_concurrency.maximum == 12
      assert subagents.parameters.properties.max_concurrency.description =~ "Defaults to 12"
    end
  end

  describe "run/3 without an ultra tag" do
    test "takes the normal loop with no addendum" do
      turn_state = build_turn_state()

      msg = %{
        channel: "telegram",
        chat_id: "normal_turn",
        sender: "user",
        content: "just answer this",
        source_trust: :operator
      }

      assert {:ok, "normal-loop-answer", _} = TurnRunner.run(msg, turn_state, fn _ -> :ok end)

      assert_receive {:chat, messages, capabilities}, 5_000
      refute Enum.any?(messages, &(&1.content =~ "Exhaustive mode"))

      # Without the ultra tag the subagents schema keeps the regular caps (§4).
      subagents = Enum.find(capabilities, &(&1.name == "subagents"))
      assert subagents.parameters.properties.tasks.maxItems == 10
      assert subagents.parameters.properties.max_concurrency.maximum == 8
    end
  end

  defp build_turn_state do
    registry_name = :"ultra_registry_#{System.unique_integer([:positive])}"
    store_name = :"ultra_store_#{System.unique_integer([:positive])}"

    start_supervised!({CapabilityRegistry, name: registry_name})

    store =
      start_supervised!({ConversationStore, name: store_name, max_messages: :infinity, repo: nil})

    %{
      adapter: CapturingAdapter,
      adapter_opts: [model: "mock-model"],
      provider: nil,
      adapter_overrides: [],
      capability_registry: registry_name,
      conversation_store: store,
      runtime_context: runtime_context(),
      memory_agent_id: "main",
      memory_owner_id: "default",
      skill_registry: nil,
      agent_supervisor: nil,
      task_supervisor: self(),
      journal_base_dir: nil,
      memory_store: nil,
      memory_repo: nil
    }
  end

  defp runtime_context do
    %RuntimeContext{
      agent_id: "main",
      built_at_ms: 0,
      base_messages: [%{role: "system", content: "base prompt"}],
      base_accounting: [],
      available_skills: [],
      operator_profile: runtime_profile(:operator),
      guest_profile: runtime_profile(:guest)
    }
  end

  defp runtime_profile(trust) do
    %{
      trust: trust,
      capabilities: capabilities_for(trust),
      runtime_message: %{role: "system", content: "runtime contract"},
      runtime_accounting: %{part: :runtime}
    }
  end

  # Only the operator profile carries the `subagents` capability — the schema
  # the loop refreshes per-turn is what the ultra-widening test asserts against.
  defp capabilities_for(:operator), do: [BuiltinCapability.from_tool_module(Subagents)]
  defp capabilities_for(_trust), do: []
end
