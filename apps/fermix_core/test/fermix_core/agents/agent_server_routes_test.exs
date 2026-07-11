defmodule FermixCore.Agents.AgentServerRoutesTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.AgentServer
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Providers.Error, as: ProviderError

  defmodule InheritedAdapter do
    def chat(_messages, _capabilities, opts) do
      send(opts[:test_pid], {:chat, :inherited, opts[:model]})

      {:ok,
       %{
         content: "from inherited chain",
         tool_calls: [],
         provider_state: nil,
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: opts[:model]
       }}
    end
  end

  defmodule FlakyAdapter do
    def chat(_messages, _capabilities, opts) do
      send(opts[:test_pid], {:chat, :flaky})
      {:error, ProviderError.transport(:anthropic, __MODULE__, :timeout)}
    end
  end

  defmodule EffortAdapter do
    def chat(_messages, _capabilities, opts) do
      send(opts[:test_pid], {:chat, :effort, opts[:model], opts[:reasoning_effort]})

      {:ok,
       %{
         content: "from effort route",
         tool_calls: [],
         provider_state: nil,
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: opts[:model]
       }}
    end
  end

  setup do
    registry = :"agent_server_routes_registry_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})

    providers = Application.get_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :providers, [])
    on_exit(fn -> Application.put_env(:fermix_core, :providers, providers) end)

    %{registry: registry}
  end

  defp definition(overrides) do
    struct!(
      %AgentDefinition{
        name: "subagent:test",
        description: "test worker",
        role: :sub,
        persistent: false,
        system_prompt: "You are a test worker.",
        model: nil,
        provider: nil,
        temperature: nil,
        capabilities: [],
        allowed_tools: nil,
        policy: [:read_only],
        trust: :operator,
        max_iterations: 3,
        timeout_seconds: 5,
        parent: "main",
        delegates_to: []
      },
      overrides
    )
  end

  defp route(provider, model, adapter) do
    {%{provider: provider, model: model, auth_mode: :api_key, base_url: "https://t/v1"},
     [adapter: adapter, model: model, test_pid: self()]}
  end

  defp start_worker(definition, opts) do
    start_supervised!(
      {AgentServer,
       [definition: definition, session_id: "sub-test-#{System.unique_integer([:positive])}"] ++
         opts}
    )
  end

  test "a worker without overrides inherits the parent turn-start route chain", %{
    registry: registry
  } do
    pid =
      start_worker(definition([]),
        capability_registry: registry,
        provider: nil,
        ordered_routes: [route(:anthropic, "claude-x", InheritedAdapter)]
      )

    assert {:ok, %{response: "from inherited chain"}} = AgentServer.run_task(pid, "do it")
    assert_received {:chat, :inherited, "claude-x"}
  end

  test "the inherited fallback list is not lost — an eligible failure moves down the chain",
       %{registry: registry} do
    pid =
      start_worker(definition([]),
        capability_registry: registry,
        provider: nil,
        ordered_routes: [
          route(:anthropic, "claude-x", FlakyAdapter),
          route(:openai, "gpt-x", InheritedAdapter)
        ]
      )

    assert {:ok, %{response: "from inherited chain"}} = AgentServer.run_task(pid, "do it")
    assert_received {:chat, :flaky}
    assert_received {:chat, :inherited, "gpt-x"}
  end

  test "an explicit definition provider stays strict and ignores the inherited chain", %{
    registry: registry
  } do
    pid =
      start_worker(definition(provider: :xai, model: "grok-4.3"),
        capability_registry: registry,
        provider: nil,
        ordered_routes: [route(:anthropic, "claude-x", InheritedAdapter)]
      )

    # The strict xAI route has no credentials, so its adapter preflights a
    # structured auth error without any network call — proof the worker
    # resolved the explicit override rather than the inherited chain.
    assert {:error, {:provider_error, %{provider: :xai, kind: :auth}}} =
             AgentServer.run_task(pid, "do it")

    refute_received {:chat, :inherited, _model}
  end

  test "an effort-only override overlays the inherited route — model kept, effort clamped", %{
    registry: registry
  } do
    pid =
      start_worker(definition(reasoning_effort: :max),
        capability_registry: registry,
        provider: nil,
        ordered_routes: [route(:xai, "grok-4.3", EffortAdapter)]
      )

    assert {:ok, _} = AgentServer.run_task(pid, "do it")
    # Inherited model preserved; :max clamps down to xAI's ceiling :high.
    assert_received {:chat, :effort, "grok-4.3", :high}
  end

  test "an effort-only override keeps the inherited fallback chain (failover preserved)", %{
    registry: registry
  } do
    pid =
      start_worker(definition(reasoning_effort: :max),
        capability_registry: registry,
        provider: nil,
        ordered_routes: [
          route(:xai, "grok-x", FlakyAdapter),
          route(:openai, "gpt-x", EffortAdapter)
        ]
      )

    assert {:ok, _} = AgentServer.run_task(pid, "do it")
    assert_received {:chat, :flaky}
    # Second route still reached (effort-only did NOT collapse to one route);
    # :max is a supported OpenAI level, so it passes through unchanged.
    assert_received {:chat, :effort, "gpt-x", :max}
  end
end
