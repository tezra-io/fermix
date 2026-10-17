defmodule FermixChannels.X.BoundaryTest do
  # The X channel's public boundary (MILESTONE_63 stage 2): an assignment
  # reaches the agent through the real gateway and the real Authorizer as a
  # guest turn that carries only its result closures, and the prompt the
  # runtime context builds for that trust holds none of the owner's memory
  # (SC-01) and none of the surface a guest is not offered. The store, the
  # prompt files and the channel config are the test's own, set through app
  # env and restored, so this module is synchronous.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.X
  alias FermixChannels.Gateway
  alias FermixChannels.Test.XConnectHelper, as: Fixtures
  alias FermixChannels.Test.XConnectHelper.FakeAgent
  alias FermixChannels.X.Assignment
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixTestSupport.SafeRm

  @agent_id "main"
  @canary "CANARY-7f41-owner-lives-on-Quillfeather-Lane"

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("x-boundary")
    repo = :"x_boundary_repo_#{unique}"
    registry = :"x_boundary_capabilities_#{unique}"

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({CapabilityRegistry, name: registry})

    previous = %{
      memory: Application.get_env(:fermix_core, :memory),
      bootstrap: Application.get_env(:fermix_core, :prompt_bootstrap),
      x: Application.get_env(:fermix_channels, :x)
    }

    memory =
      Keyword.merge(previous.memory || [],
        repo: repo,
        prompt_base_dir: Path.join(dir, "memory"),
        agent_id: @agent_id
      )

    Application.put_env(:fermix_core, :memory, memory)

    Application.put_env(:fermix_core, :prompt_bootstrap,
      bootstrap_dir: Path.join(dir, "bootstrap")
    )

    # A config that asks for streaming: the channel is final-only whatever it says.
    Application.put_env(:fermix_channels, :x, enabled: true, streaming: "block")

    on_exit(fn ->
      restore_env(:fermix_core, :memory, previous.memory)
      restore_env(:fermix_core, :prompt_bootstrap, previous.bootstrap)
      restore_env(:fermix_channels, :x, previous.x)
      SafeRm.rm_rf(dir)
    end)

    %{repo: repo, registry: registry}
  end

  # A verified assignment whose row is running, as the pump leaves it once
  # Connect granted the start; the message is the one the pump would ingest.
  defp running_message!(ctx, id) do
    {_public, seed} = Fixtures.connect_key()

    {:ok, assignment} =
      %{"assignment_id" => id, "interaction_id" => "ix_" <> id}
      |> Fixtures.payload()
      |> Fixtures.sign(seed)
      |> Assignment.claims()

    claim = %{
      assignment_id: id,
      interaction_id: assignment.interaction_id,
      tenant_id: assignment.tenant_id,
      instance_id: assignment.instance_id,
      requester_x_user_id: assignment.requester_x_user_id,
      conversation_id: assignment.conversation_id,
      request_sha256: assignment.request_sha256,
      jws: "aGVhZGVy.cGF5bG9hZA.c2ln",
      expires_at: ~U[2099-01-01 00:00:00Z],
      claimed_at: DateTime.utc_now()
    }

    {:ok, {:claimed, _row}} = Repo.x_claim_assignment(claim, server: ctx.repo)

    grant = %{
      attempt: 1,
      runner_epoch: "epoch-boundary",
      deadline_at: ~U[2099-01-01 00:00:00Z],
      now: DateTime.utc_now()
    }

    {:ok, _row} = Repo.x_start_assignment(id, grant, server: ctx.repo)
    X.message(assignment)
  end

  defp ingest(message, opts \\ []) do
    Gateway.ingest(
      [message],
      Keyword.merge([channel: X, agent: FakeAgent, agent_server: self()], opts)
    )
  end

  defp ingest_with_proof!(message) do
    assert :ok = ingest(message, ingress_context: %{transport: :x, assignment_id: message.id})
    assert_receive {:agent_message, agent_message}
    agent_message
  end

  defp write_prompt_file(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  test "an assignment reaches the agent as a guest turn with only its result closures", ctx do
    agent_message = ingest_with_proof!(running_message!(ctx, "as_boundary"))

    assert agent_message.channel == "x"
    assert agent_message.source_trust == :guest
    assert is_function(agent_message.reply_fn, 1)
    assert is_function(agent_message.turn_result_fn, 1)
    assert agent_message.terminal_error_owner? == true
    # The queue sends it nothing but the turn's own reply (no canned retry,
    # no compaction notice): its text closure is the published result.
    assert agent_message.final_only? == true

    for key <- [
          :approval_fn,
          :owner_inbox_approval_fn,
          :private_approval_button?,
          :typing_fn,
          :stream_spec,
          :reaction_spec,
          :activity_callback
        ] do
      refute Map.has_key?(agent_message, key), "an X turn must not carry #{key}"
    end

    assert ConversationKey.from(agent_message) ==
             {"x", "1234567890:1234567890:1", "1844999999999999990"}
  end

  test "without the pump's proof the same message reaches nothing", ctx do
    message = running_message!(ctx, "as_unproven")

    assert :ok = ingest(message)

    forged = %{
      message
      | metadata: Map.put(message.metadata, :transport_auth, {:connect_assignment, message.id})
    }

    assert :ok =
             ingest(forged, ingress_context: %{transport: :mobile, authenticated_device_id: "d1"})

    refute_received {:agent_message, _agent_message}
  end

  test "a slash command in a mention is the model's text, never a command", ctx do
    message = %{running_message!(ctx, "as_slash") | content: "/stop"}

    assert %{content: "/stop", source_trust: :guest} = ingest_with_proof!(message)
  end

  test "the owner's USER.md and MEMORY.md never reach an X turn's prompt (SC-01)", ctx do
    write_prompt_file(Path.join(BootstrapPaths.agent_dir(@agent_id), "IDENTITY.md"), "identity")
    memory_dir = Path.dirname(PromptFiles.user_path(@agent_id))
    write_prompt_file(Path.join(memory_dir, "USER.md"), "## Identity\n- #{@canary}")
    write_prompt_file(Path.join(memory_dir, "MEMORY.md"), "## Working Rules\n- #{@canary}")

    agent_message = ingest_with_proof!(running_message!(ctx, "as_canary"))

    {:ok, runtime} =
      RuntimeContext.build(
        agent_id: @agent_id,
        available_skills: [],
        capability_registry: ctx.registry
      )

    user_message = %{role: "user", content: agent_message.content}
    profile = RuntimeContext.profile_for(runtime, agent_message.source_trust, ctx.registry, [])

    prompt =
      runtime
      |> RuntimeContext.messages_for(profile, [], user_message)
      |> Enum.map_join("\n", & &1.content)

    refute prompt =~ @canary
    assert prompt =~ "@FermixAI explain this"

    # The canary is in the owner's memory: an operator turn would carry it.
    operator =
      runtime
      |> RuntimeContext.messages_for(runtime.operator_profile, [], user_message)
      |> Enum.map_join("\n", & &1.content)

    assert operator =~ @canary
  end

  test "over every built-in the seeder can register, an X turn is offered only the guest surface",
       ctx do
    for module <- BuiltinSeeder.builtin_tool_modules() do
      :ok = CapabilityRegistry.register(ctx.registry, Builtin.from_tool_module(module))
    end

    agent_message = ingest_with_proof!(running_message!(ctx, "as_surface"))
    profile = RuntimeContext.build_profile(agent_message.source_trust, [], ctx.registry)

    assert profile.dispatchable != []

    for capability <- profile.dispatchable do
      assert capability.policy_class == :read_only,
             "an X turn was offered #{capability.name} (#{capability.policy_class})"

      refute capability.owner_only?, "an X turn was offered the owner's #{capability.name}"
    end

    # The seeded surface holds what a guest must not reach, so the filter is
    # what kept it out.
    operator = RuntimeContext.build_profile(:operator, [], ctx.registry)
    assert Enum.any?(operator.dispatchable, &(&1.policy_class != :read_only or &1.owner_only?))
  end
end
