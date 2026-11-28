defmodule FermixCore.AgentLoopToolErrorActivityTest do
  # M106 §6: a scheduled run keeps each tool's last error text, so its
  # `:tool_finish` activity can carry a failed call's error, cut to a bound,
  # as the tool gave it and not as the model was shown it (framed). Only a
  # caller that asks for it (`activity_error_chars`) gets it: every other
  # consumer of the activity (the ACP session, the apps' tool feed) sees the
  # event exactly as before.
  use ExUnit.Case, async: true

  alias FermixCore.AgentLoop
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  defmodule ScriptAdapter do
    @moduledoc false
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, opts), do: next_turn(Keyword.fetch!(opts, :script))

    @impl true
    def continue(%{rest: rest}, _tool_results, _opts), do: next_turn(rest)

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp next_turn([turn | rest]) do
      {:ok,
       Map.merge(
         %{
           content: "",
           tool_calls: [],
           usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
           model: "mock",
           provider_state: %{rest: rest}
         },
         turn
       )}
    end
  end

  @words "needs reconnection: station 4 is asleep"

  setup do
    registry = :"tool_error_activity_caps_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})

    :ok = CapabilityRegistry.register(registry, capability("harbour_whoami", :refuse, true))
    :ok = CapabilityRegistry.register(registry, capability("tide_echo", :answer, false))
    %{registry: registry}
  end

  test "with no bound asked for, a failed call's finish carries its status alone", %{
    registry: registry
  } do
    assert {:ok, _result} = run(registry, [])

    assert finishes() == [
             {"harbour_whoami", %{status: :error}},
             {"tide_echo", %{status: :ok}},
             {"no_such_tool", %{status: :error}}
           ]
  end

  test "with a bound, a failed call's finish carries its error as the tool gave it, cut to the bound",
       %{registry: registry} do
    assert {:ok, _result} = run(registry, activity_error_chars: 500)

    assert [
             {"harbour_whoami", %{status: :error, error: @words}},
             {"tide_echo", %{status: :ok} = ok},
             {"no_such_tool", %{status: :error, error: "Error: Tool 'no_such_tool' not found"}}
           ] = finishes()

    refute Map.has_key?(ok, :error)

    assert {:ok, _result} = run(registry, activity_error_chars: 12)

    assert [
             {"harbour_whoami", %{error: "needs reconn"}},
             {"tide_echo", %{status: :ok}},
             {"no_such_tool", %{error: "Error: Tool "}}
           ] = finishes()
  end

  defp run(registry, opts) do
    test_pid = self()

    calls =
      for {name, n} <- Enum.with_index(["harbour_whoami", "tide_echo", "no_such_tool"]) do
        %{id: "fc_#{n}", call_id: "call_#{n}", name: name, arguments: "{}"}
      end

    AgentLoop.run(
      [
        messages: [%{role: "user", content: "Who am I on the harbour service?"}],
        adapter: ScriptAdapter,
        adapter_opts: [model: "mock", script: [%{tool_calls: calls}, %{content: "Done."}]],
        capability_registry: registry,
        context: %{agent_name: "test", conversation_key: :test},
        activity_callback: fn event -> send(test_pid, {:activity, event}) end
      ] ++ opts
    )
  end

  defp finishes do
    receive do
      {:activity, {:tool_finish, name, detail}} -> [{name, detail} | finishes()]
      {:activity, _other} -> finishes()
    after
      0 -> []
    end
  end

  def execute(_args, _context, :refuse), do: {:ok, %{success: false, output: "", error: @words}}
  def execute(_args, _context, :answer), do: {:ok, %{success: true, output: "High water."}}

  # The refusing tool is a plugin's, so the model is shown its error framed as
  # outside content; the activity carries the words themselves.
  defp capability(name, behaviour, plugin?) do
    capability =
      Capability.new(%{
        name: name,
        description: "Test capability #{name}",
        parameters: %{"type" => "object", "properties" => %{}},
        kind: :builtin,
        executor: {__MODULE__, :execute, [behaviour]},
        policy_class: :read_only
      })

    if plugin?,
      do: %{capability | metadata: %{plugin_owned?: true, plugin: "harbour_id"}},
      else: capability
  end
end
