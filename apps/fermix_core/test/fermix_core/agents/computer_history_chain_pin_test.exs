defmodule FermixCore.Agents.ComputerHistoryChainPinTest do
  @moduledoc """
  MILESTONE_32 §9.4 chain pinning, asserted at the seam that carries it: the
  turn state `MainAgent` hands the gateway. Everything downstream — the loop's
  route chain, the taint masks, a subagent's inherited chain — reads
  `turn_state.ordered_routes`, so this is the one place the pin is applied and
  the one place it has to be proven.

  The platform is injected (`computer_history_macos?`), the provider chain comes
  from config the test establishes, and `FERMIX_HOME` points at a throwaway dir
  so no host credential can add a hop.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore

  setup do
    # The pin line is Logger.info and config/test.exs pins the primary level to
    # :warning, which drops it before any capture handler sees it. Establish the
    # precondition here rather than assuming it, and put it back after.
    previous_level = Logger.level()
    Logger.configure(level: :info)

    suffix = System.unique_integer([:positive])
    previous = for key <- env_keys(), into: %{}, do: {key, Application.get_env(:fermix_core, key)}
    fermix_home = System.get_env("FERMIX_HOME")
    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("ch-chain-pin")
    skills_dir = Path.join(tmp_home, "skills")
    prompt_dir = Path.join(tmp_home, "prompt")
    File.mkdir_p!(skills_dir)
    File.mkdir_p!(prompt_dir)

    System.put_env("FERMIX_HOME", tmp_home)
    Application.put_env(:fermix_core, :agent, [])
    Application.put_env(:fermix_core, :routing, [])

    Application.put_env(:fermix_core, :providers,
      openai: [api_key: "sk-test", primary: true],
      anthropic: [api_key: "sk-ant"]
    )

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous[:memory] || [], prompt_base_dir: prompt_dir, agent_id: "main")
    )

    on_exit(fn ->
      Logger.configure(level: previous_level)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      restore_home(fermix_home)
      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
    end)

    %{agent: start_main_agent(suffix, skills_dir)}
  end

  defp env_keys, do: [:agent, :routing, :providers, :memory, :computer_history]

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)

  defp start_main_agent(suffix, skills_dir) do
    capability_registry = :"ch_pin_caps_#{suffix}"
    skill_registry = :"ch_pin_skills_#{suffix}"
    conversation_store = :"ch_pin_conv_#{suffix}"
    task_supervisor = :"ch_pin_tasks_#{suffix}"
    agent_name = :"ch_pin_agent_#{suffix}"

    start_supervised!({Task.Supervisor, name: task_supervisor}, id: task_supervisor)
    start_supervised!({CapabilityRegistry, name: capability_registry}, id: capability_registry)

    start_supervised!(
      {SkillRegistry,
       name: skill_registry,
       skills_dir: skills_dir,
       seed_defaults: false,
       capability_registry: capability_registry},
      id: skill_registry
    )

    start_supervised!({ConversationStore, name: conversation_store}, id: conversation_store)

    start_supervised!(
      {MainAgent,
       name: agent_name,
       capability_registry: capability_registry,
       skill_registry: skill_registry,
       conversation_store: conversation_store,
       task_supervisor: task_supervisor,
       computer_history_macos?: true},
      id: agent_name
    )

    agent_name
  end

  defp enable_history(kw) do
    Application.put_env(:fermix_core, :computer_history, [enabled: true] ++ kw)
  end

  defp message(trust) do
    %{
      content: "what was I working on?",
      sender: "owner",
      channel: "telegram",
      chat_id: "chat_#{System.unique_integer([:positive])}",
      source_trust: trust
    }
  end

  defp providers(routes), do: Enum.map(routes, fn {route_key, _opts} -> route_key.provider end)

  test "an attended owner turn runs only on the hops granted for history", %{agent: agent} do
    enable_history(summarizer: :local, remote_summaries: [:openai])

    log =
      capture_log([level: :info], fn ->
        assert {:ok, turn_state, _cache} =
                 MainAgent.checkout_turn_state(agent, message(:operator))

        send(self(), {:turn_state, turn_state})
      end)

    assert_received {:turn_state, turn_state}

    assert providers(turn_state.ordered_routes) == [:openai]
    assert turn_state.computer_history_gate.dropped_hops == [:anthropic]
    assert turn_state.computer_history_gate.chain_ok?
    assert log =~ "computer_history: owner turn pinned to openai"
    assert log =~ "failover to anthropic disabled while history is on"
  end

  test "a guest turn keeps the whole configured chain", %{agent: agent} do
    enable_history(summarizer: :local, remote_summaries: [:openai])

    assert {:ok, turn_state, _cache} = MainAgent.checkout_turn_state(agent, message(:guest))

    assert providers(turn_state.ordered_routes) == [:openai, :anthropic]
    assert turn_state.computer_history_gate.dropped_hops == []
  end

  test "history disabled leaves the chain and the failover semantics untouched", %{agent: agent} do
    Application.put_env(:fermix_core, :computer_history, enabled: false)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, turn_state, _cache} =
                 MainAgent.checkout_turn_state(agent, message(:operator))

        send(self(), {:turn_state, turn_state})
      end)

    assert_received {:turn_state, turn_state}

    assert providers(turn_state.ordered_routes) == [:openai, :anthropic]
    refute log =~ "owner turn pinned"
  end

  test "an ungranted lead is never replaced by a granted fallback", %{agent: agent} do
    # The primary stays the primary: granting only the fallback must not promote
    # it, and history simply does not surface on this turn.
    enable_history(summarizer: :local, remote_summaries: [:anthropic])

    assert {:ok, turn_state, _cache} = MainAgent.checkout_turn_state(agent, message(:operator))

    assert providers(turn_state.ordered_routes) == [:openai, :anthropic]
    refute turn_state.computer_history_gate.chain_ok?
  end
end
