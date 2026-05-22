defmodule FermixCore.Agents.RuntimeContextTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Prompt.BootstrapPaths

  defmodule FakeMod do
    def execute(_args, _ctx, _extra \\ nil), do: {:ok, :ok}
  end

  setup do
    unique = System.unique_integer([:positive, :monotonic])
    bootstrap_dir = Path.join(System.tmp_dir!(), "fermix-runctx-bootstrap-#{unique}")
    memory_dir = Path.join(System.tmp_dir!(), "fermix-runctx-memory-#{unique}")
    previous_bootstrap = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    previous_memory = Application.get_env(:fermix_core, :memory, [])

    Application.put_env(:fermix_core, :prompt_bootstrap, bootstrap_dir: bootstrap_dir)

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_memory, prompt_base_dir: memory_dir, agent_id: "main")
    )

    registry_name = :"runctx_reg_#{unique}"
    start_supervised!({CapabilityRegistry, name: registry_name})

    on_exit(fn ->
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_bootstrap)
      Application.put_env(:fermix_core, :memory, previous_memory)
      FermixTestSupport.SafeRm.rm_rf!(bootstrap_dir)
      FermixTestSupport.SafeRm.rm_rf!(memory_dir)
    end)

    %{agent_id: "main", registry: registry_name}
  end

  defp cap(name, opts \\ []) do
    Capability.new(%{
      name: name,
      description: "test #{name}",
      parameters: %{type: "object"},
      kind: Keyword.get(opts, :kind, :builtin),
      executor: {FakeMod, :execute, []},
      policy_class: Keyword.get(opts, :policy_class, :read_only),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  defp write_bootstrap(agent_id, file, content) do
    path = Path.join(BootstrapPaths.agent_dir(agent_id), file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp write_memory(agent_id, file, content) do
    path = Path.join(Path.dirname(PromptFiles.user_path(agent_id)), file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  test "build/1 composes base + operator profile from registry", %{
    agent_id: agent_id,
    registry: registry
  } do
    write_bootstrap(agent_id, "IDENTITY.md", "identity content")
    write_bootstrap(agent_id, "AGENTS.md", "agents content")
    write_memory(agent_id, "USER.md", "user content")

    :ok = CapabilityRegistry.register(registry, cap("read_tool", policy_class: :read_only))
    :ok = CapabilityRegistry.register(registry, cap("exec_tool", policy_class: :exec))

    assert {:ok, ctx} =
             RuntimeContext.build(
               agent_id: agent_id,
               available_skills: [],
               capability_registry: registry
             )

    assert ctx.agent_id == agent_id

    # Base messages exclude the runtime section
    assert Enum.all?(ctx.base_messages, fn message ->
             refute message.content =~ "## Runtime Contract"
             true
           end)

    operator_names = Enum.map(ctx.operator_profile.capabilities, & &1.name)
    assert "read_tool" in operator_names
    assert "exec_tool" in operator_names

    assert ctx.operator_profile.runtime_message.role == "system"
    assert ctx.operator_profile.runtime_message.content =~ "## Runtime Contract"
    assert ctx.operator_profile.runtime_message.content =~ "`read_tool`"
    assert ctx.operator_profile.runtime_message.content =~ "`exec_tool`"
  end

  test "profile_for/4 returns the cached operator profile object identity", %{
    agent_id: agent_id,
    registry: registry
  } do
    :ok = CapabilityRegistry.register(registry, cap("read_tool"))

    {:ok, ctx} =
      RuntimeContext.build(
        agent_id: agent_id,
        available_skills: [],
        capability_registry: registry
      )

    assert RuntimeContext.profile_for(ctx, :operator, registry, []) == ctx.operator_profile
  end

  test "profile_for/4 returns cached guest profile and filters exec capabilities", %{
    agent_id: agent_id,
    registry: registry
  } do
    :ok = CapabilityRegistry.register(registry, cap("read_tool", policy_class: :read_only))
    :ok = CapabilityRegistry.register(registry, cap("exec_tool", policy_class: :exec))

    {:ok, ctx} =
      RuntimeContext.build(
        agent_id: agent_id,
        available_skills: [],
        capability_registry: registry
      )

    guest = RuntimeContext.profile_for(ctx, :guest, registry, [])

    guest_names = Enum.map(guest.capabilities, & &1.name)
    assert "read_tool" in guest_names
    refute "exec_tool" in guest_names
    refute guest.runtime_message.content =~ "`exec_tool`"

    :ok = CapabilityRegistry.register(registry, cap("late_read_tool", policy_class: :read_only))
    same_guest = RuntimeContext.profile_for(ctx, :guest, registry, [])

    same_guest_names = Enum.map(same_guest.capabilities, & &1.name)
    refute "late_read_tool" in same_guest_names
  end

  test "guest profile excludes skills hidden by trust filter", %{
    agent_id: agent_id,
    registry: registry
  } do
    operator_skill = %AgentDefinition{
      name: "operator-skill",
      role: :sub,
      persistent: false,
      system_prompt: "Operator-only.",
      capabilities: [],
      allowed_tools: [],
      max_iterations: 4,
      timeout_seconds: 60,
      parent: nil,
      delegates_to: []
    }

    # Register the skill capability the way SkillRegistry would —
    # kind: :skill, policy_class: :exec.
    :ok =
      CapabilityRegistry.register(
        registry,
        cap("operator-skill", kind: :skill, policy_class: :exec)
      )

    {:ok, ctx} =
      RuntimeContext.build(
        agent_id: agent_id,
        available_skills: [operator_skill],
        capability_registry: registry
      )

    assert ctx.operator_profile.runtime_message.content =~ "- operator-skill"

    guest = RuntimeContext.profile_for(ctx, :guest, registry, [])

    refute guest.runtime_message.content =~ "- operator-skill"
  end

  test "messages_for/4 assembles base + runtime + history + user", %{
    agent_id: agent_id,
    registry: registry
  } do
    write_bootstrap(agent_id, "IDENTITY.md", "identity content")
    :ok = CapabilityRegistry.register(registry, cap("read_tool"))

    {:ok, ctx} =
      RuntimeContext.build(
        agent_id: agent_id,
        available_skills: [],
        capability_registry: registry
      )

    history = [%{role: "assistant", content: "previous reply"}]
    user_message = %{role: "user", content: "new turn"}

    messages = RuntimeContext.messages_for(ctx, ctx.operator_profile, history, user_message)

    assert List.last(messages) == user_message
    assert Enum.at(messages, -2) == hd(history)

    runtime_index = length(ctx.base_messages)
    assert Enum.at(messages, runtime_index) == ctx.operator_profile.runtime_message
  end

  test "accounting_for/2 returns base + runtime accounting", %{
    agent_id: agent_id,
    registry: registry
  } do
    write_bootstrap(agent_id, "IDENTITY.md", "identity content")
    :ok = CapabilityRegistry.register(registry, cap("read_tool"))

    {:ok, ctx} =
      RuntimeContext.build(
        agent_id: agent_id,
        available_skills: [],
        capability_registry: registry
      )

    accounting = RuntimeContext.accounting_for(ctx, ctx.operator_profile)
    last_entry = List.last(accounting)

    assert last_entry.name == :runtime
    assert last_entry.source_path == nil
    assert last_entry.approx_size > 0
  end

  test "build/1 surfaces base composition errors via {:error, ...}", %{
    registry: registry
  } do
    # Force compose_base_with_metadata to fail by pointing the agent_id
    # at a path that includes a parent traversal — BootstrapPaths.validate_agent_id
    # rejects it.
    assert {:error, _reason} =
             RuntimeContext.build(
               agent_id: "../escape",
               available_skills: [],
               capability_registry: registry
             )
  end
end
