defmodule FermixCore.Agents.TurnRunnerUltraTest do
  @moduledoc """
  The routing seam for `/ultra` (§17.11): a message tagged `run_profile: :ultra`
  must reach `UltraOrchestrator` (injectable) instead of the normal agent loop,
  return the `{:ok, response, 0}` three-tuple the queue expects, and be handed a
  complete deps map plus a live arity-1 `deliver`. An untagged message must still
  take the normal loop path unchanged.
  """
  use ExUnit.Case, async: false

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore

  defmodule LoopingAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, _opts) do
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

  # Injected stand-in for UltraOrchestrator: records the prompt + deps it was
  # handed (so the test can prove the wiring is complete), exercises `deliver`,
  # then returns the orchestrator's `{:ok, response}` contract.
  defmodule CapturingOrchestrator do
    def run(prompt, deps) do
      pid = Application.fetch_env!(:fermix_core, :ultra_test_pid)
      deps.deliver.({:text, "stub-progress"})
      send(pid, {:ultra_invoked, prompt, Map.keys(deps)})
      {:ok, "ultra-orchestrator-answer"}
    end
  end

  setup do
    prior = Application.get_env(:fermix_core, :ultra_orchestrator)
    prior_pid = Application.get_env(:fermix_core, :ultra_test_pid)

    on_exit(fn ->
      restore(:ultra_orchestrator, prior)
      restore(:ultra_test_pid, prior_pid)
    end)

    :ok
  end

  describe "run/3 with run_profile: :ultra" do
    test "routes into the orchestrator and returns the {:ok, response, 0} three-tuple" do
      Application.put_env(:fermix_core, :ultra_orchestrator, CapturingOrchestrator)
      Application.put_env(:fermix_core, :ultra_test_pid, self())

      turn_state = build_turn_state()
      test_pid = self()
      deliver = fn part -> send(test_pid, {:delivered, part}) end

      msg = %{
        channel: "telegram",
        chat_id: "ultra_turn",
        sender: "user",
        content: "plan a complex trip",
        source_trust: :operator,
        metadata: %{run_profile: :ultra}
      }

      assert {:ok, "ultra-orchestrator-answer", 0} = TurnRunner.run(msg, turn_state, deliver)

      # The orchestrator saw the raw prompt and a deps map with every stage wired,
      # plus the verify-stage concurrency knob the wide /ultra fan-out needs.
      assert_receive {:ultra_invoked, "plan a complex trip", deps_keys}, 5_000

      assert Enum.sort(deps_keys) ==
               [:decompose, :deliver, :fanout, :synthesize, :verify, :verify_concurrency]

      # `deliver` is a live arity-1 reply_fn the orchestrator can narrate through.
      assert_receive {:delivered, {:text, "stub-progress"}}, 5_000
    end
  end

  describe "run/3 without an ultra tag" do
    test "takes the normal agent-loop path unchanged" do
      turn_state = build_turn_state()

      msg = %{
        channel: "telegram",
        chat_id: "normal_turn",
        sender: "user",
        content: "just answer this",
        source_trust: :operator
      }

      assert {:ok, "normal-loop-answer", _context_tokens} =
               TurnRunner.run(msg, turn_state, fn _part -> :ok end)
    end
  end

  defp build_turn_state do
    registry_name = :"ultra_registry_#{System.unique_integer([:positive])}"
    store_name = :"ultra_store_#{System.unique_integer([:positive])}"

    start_supervised!({CapabilityRegistry, name: registry_name})

    store =
      start_supervised!({ConversationStore, name: store_name, max_messages: :infinity, repo: nil})

    %{
      adapter: LoopingAdapter,
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
      capabilities: [],
      runtime_message: %{role: "system", content: "runtime contract"},
      runtime_accounting: %{part: :runtime}
    }
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
