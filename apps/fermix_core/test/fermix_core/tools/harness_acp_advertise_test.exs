defmodule FermixCore.Tools.HarnessAcpAdvertiseTest do
  # async: false — the gate reads the global `:harness` app env, the vendor
  # detector seam, and the prompt-bootstrap/memory dirs; all are forced here and
  # restored on exit.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias FermixCore.Acp.Identity
  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixTestSupport.SafeRm

  # MILESTONE_29_ACP_AGENT_SURFACE §17.6: the harness gate on this surface is no
  # longer "not acp" but "is this session bound to a posting-capable identity" —
  # a run launched here reports back through a continuation turn that signs and
  # posts with the client's own credentials, so a session that has none must be
  # offered nothing.
  #
  # The tool list is READ FROM THE SEEDER (`BuiltinSeeder.harness_modules/1`,
  # the same source that decides which harness tools get registered), never
  # spelled out here: the M28 lesson is that a feature-level gate asserted over a
  # hand-written list drifts the moment an eighth tool is added. With every seam
  # forced on, `harness_modules/1` returns the whole family.

  # Published NIP-19 vector (see nostr/key_test.exs for its derivation) — a test
  # vector, never a live key.
  @nsec "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"

  defmodule EchoAdapter do
    @behaviour FermixCore.Providers.Adapter

    # Reports the two halves of the turn's surface together: the messages the
    # model was given (the prompt half) and the schemas it was offered (the wire
    # half). One turn, one report — which is what makes the one-list property
    # testable rather than aspirational.
    @impl true
    def chat(messages, capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:turn_surface, messages, capabilities})

      {:ok,
       %{
         content: "done",
         tool_calls: [],
         provider_state: %{},
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: "mock-model"
       }}
    end

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, :unexpected_continue}

    @impl true
    def to_provider_tools(_capabilities), do: []

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  defp seeded_harness_tools do
    BuiltinSeeder.harness_modules(
      harness_enabled: true,
      cloud_enabled: true,
      vendor_available_fn: fn _vendor -> true end
    )
  end

  setup do
    unique = System.unique_integer([:positive, :monotonic])
    prior_harness = Application.get_env(:fermix_core, :harness)
    prior_detector = Application.get_env(:fermix_core, :harness_vendor_detector)
    prior_bootstrap = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    prior_memory = Application.get_env(:fermix_core, :memory, [])

    bootstrap_dir = Path.join(System.tmp_dir!(), "fermix-acp-advertise-boot-#{unique}")
    memory_dir = Path.join(System.tmp_dir!(), "fermix-acp-advertise-mem-#{unique}")

    Application.put_env(:fermix_core, :harness, enabled: true, approved: true)
    Application.put_env(:fermix_core, :prompt_bootstrap, bootstrap_dir: bootstrap_dir)

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(prior_memory, prompt_base_dir: memory_dir, agent_id: "main")
    )

    # Both CLIs present and no configured default ⇒ `advertise_vendor?` is true
    # for both run tools, so the identity is the only variable under test.
    Application.put_env(:fermix_core, :harness_vendor_detector, fn ->
      %{
        "codex" => %{vendor: "codex", available?: true},
        "claude" => %{vendor: "claude", available?: true}
      }
    end)

    on_exit(fn ->
      restore(:harness, prior_harness)
      restore(:harness_vendor_detector, prior_detector)
      Application.put_env(:fermix_core, :prompt_bootstrap, prior_bootstrap)
      Application.put_env(:fermix_core, :memory, prior_memory)
      SafeRm.rm_rf!(bootstrap_dir)
      SafeRm.rm_rf!(memory_dir)
    end)

    %{tools: seeded_harness_tools(), unique: unique}
  end

  test "the seeder still registers a harness family to gate", %{tools: tools} do
    assert length(tools) >= 7
  end

  test "every harness tool advertises on an acp turn with a posting-capable identity", %{
    tools: tools
  } do
    context = attended_context("acp", identity_env())

    for tool <- tools do
      assert tool.advertise?(context), "#{inspect(tool)} stayed hidden on a Buzz-capable ACP turn"
    end
  end

  test "no harness tool is advertised on an identity-less acp turn", %{tools: tools} do
    context = attended_context("acp", nil)

    for tool <- tools do
      refute tool.advertise?(context), "#{inspect(tool)} advertised on an identity-less ACP turn"
    end
  end

  # The axis that catches a regression of §17.2's drop rule, asserted FROM THE
  # HELLO rather than from a hand-built env: a present-but-malformed signing key
  # passes the name-keyed allowlist untouched, so only the drop rule keeps the
  # cheap gate and the store in agreement.
  test "no harness tool is advertised when the hello's signing key would not derive", %{
    tools: tools
  } do
    env = capture_env(fn -> hello_env(%{"BUZZ_PRIVATE_KEY" => "nsec1thisisnotarealkey"}) end)
    context = attended_context("acp", env)

    assert Map.has_key?(env, "PATH")
    refute Map.has_key?(env, "BUZZ_PRIVATE_KEY")

    for tool <- tools do
      refute tool.advertise?(context),
             "#{inspect(tool)} advertised on an underivable-key ACP turn"
    end
  end

  test "every harness tool still advertises on an ordinary operator channel", %{tools: tools} do
    for session_env <- [nil, identity_env()], tool <- tools do
      context = attended_context("telegram", session_env)
      assert tool.advertise?(context), "#{inspect(tool)} stayed hidden on a telegram turn"
    end
  end

  test "a turn with no channel key keeps advertising", %{tools: tools} do
    context = Map.delete(attended_context("telegram", nil), :channel)

    for tool <- tools do
      assert tool.advertise?(context), "#{inspect(tool)} stayed hidden on a channel-less turn"
    end
  end

  # The whole-surface invariant (§17.6(b), §17.9 Stage 4). Both halves are read
  # off the SAME turn: the messages the model got and the schemas it was offered
  # come out of one `chat/3` call, so a prompt that steers repository work at a
  # tool the wire does not carry — the M28 drift class — fails here.
  test "the prompt section and the advertised schemas move together on the acp surface", %{
    tools: tools,
    unique: unique
  } do
    names = Enum.map(tools, & &1.name())
    state = turn_state(unique, tools)

    assert {:ok, "done", _tokens} =
             TurnRunner.run(acp_message("bound", identity_env()), state, fn _part -> :ok end)

    assert_receive {:turn_surface, messages, capabilities}, 5_000
    assert system_prompt(messages) =~ "### Coding Harness"

    for name <- names do
      assert name in advertised_names(capabilities),
             "#{name} was missing from the wire on a Buzz-capable ACP turn"
    end

    assert {:ok, "done", _tokens} =
             TurnRunner.run(acp_message("bare", nil), state, fn _part -> :ok end)

    assert_receive {:turn_surface, bare_messages, bare_capabilities}, 5_000
    refute system_prompt(bare_messages) =~ "### Coding Harness"

    for name <- names do
      refute name in advertised_names(bare_capabilities),
             "#{name} reached the wire on an identity-less ACP turn"
    end

    # Only the harness family moves: the turn still carries its other tools.
    assert "record_marker" in advertised_names(bare_capabilities)
    assert system_prompt(bare_messages) =~ "`record_marker`"
  end

  defp identity_env, do: hello_env()

  # The one producer of a turn's session_env (§17.1), used here exactly as the
  # Peer uses it — a hand-written map would restate the drop rule instead of
  # exercising it.
  defp hello_env(overrides \\ %{}) do
    %{
      "BUZZ_PRIVATE_KEY" => @nsec,
      "BUZZ_RELAY_URL" => "wss://relay.example.test",
      "PATH" => "/opt/buzz/bin:/usr/bin",
      "OPENAI_API_KEY" => "sk-must-never-travel"
    }
    |> Map.merge(overrides)
    |> Identity.new()
    |> Identity.to_env()
  end

  # A malformed key logs one named warning on the way through `Identity.new/1`;
  # swallow it here so the failure output stays about the assertion.
  defp capture_env(fun) do
    _log = capture_log(fn -> send(self(), {:env, fun.()}) end)

    receive do
      {:env, built} -> built
    after
      0 -> flunk("the hello env was not built")
    end
  end

  defp attended_context(channel, session_env) do
    %{
      agent_name: "main",
      channel: channel,
      session_env: session_env,
      source_trust: :operator,
      subagent_depth: 0,
      reply_fn: fn _text -> :ok end,
      conversation_key: {channel, "session-1", :root},
      session_id: "main-1"
    }
  end

  defp acp_message(chat_id, session_env) do
    %{
      channel: "acp",
      chat_id: "acp_advertise_#{chat_id}",
      sender: "acp-client",
      content: "ship the fix",
      source_trust: :operator,
      session_env: session_env
    }
  end

  defp system_prompt(messages) do
    messages |> Enum.filter(&(&1.role == "system")) |> Enum.map_join("\n", & &1.content)
  end

  defp advertised_names(capabilities), do: Enum.map(capabilities, & &1.name)

  # A REAL runtime context over a REAL registry holding the seeded harness
  # modules: the prompt section is rendered by `RuntimeSections` from the same
  # capability list the wire is built from, which is the property under test.
  defp turn_state(unique, tools) do
    registry = :"acp_advertise_reg_#{unique}"
    start_supervised!({CapabilityRegistry, name: registry})

    for tool <- [FermixCore.Tools.MemoryStore | tools] do
      :ok = CapabilityRegistry.register(registry, Builtin.from_tool_module(tool))
    end

    :ok = CapabilityRegistry.register(registry, marker_capability())

    store =
      start_supervised!(
        {ConversationStore,
         name: :"acp_advertise_store_#{unique}", max_messages: :infinity, repo: nil}
      )

    assert {:ok, ctx} =
             RuntimeContext.build(
               agent_id: "main",
               available_skills: [],
               capability_registry: registry
             )

    %{
      adapter: EchoAdapter,
      adapter_opts: [model: "mock-model", test_pid: self()],
      provider: nil,
      adapter_overrides: [],
      capability_registry: registry,
      conversation_store: store,
      runtime_context: ctx,
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

  # A non-harness tool with no `advertise?/1` of its own: whatever the harness
  # gate does, this one must stay on both halves of the surface.
  defp marker_capability do
    Capability.new(%{
      name: "record_marker",
      description: "a non-harness tool that must survive the harness gate",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {__MODULE__, :noop, []},
      policy_class: :read_only,
      metadata: %{category: :system}
    })
  end

  @doc false
  def noop(_args, _context), do: {:ok, %{success: true, output: "ok"}}

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, prior), do: Application.put_env(:fermix_core, key, prior)
end
