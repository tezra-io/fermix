defmodule FermixCore.Agents.HarnessChannelProfileTest do
  # async: false — the harness gate reads the global `:harness` app env and the
  # prompt-bootstrap/memory dirs are global too; all are forced here and restored.
  use ExUnit.Case, async: false

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore

  # MILESTONE_29_ACP_AGENT_SURFACE §4 ("Detached work"): every coding-harness tool
  # self-hides on the ACP surface. The M28 lesson is that the PROSE has to move
  # with the wire — a prompt that steers repository work to `codex_run` while no
  # harness tool is advertised sends the model at a tool it cannot call. So the
  # profile a client-owned channel gets is built from ONE list with the `:harness`
  # category excluded: catalog section and advertised schemas together.

  defmodule FakeMod do
    def execute(_args, _context, _extra \\ nil), do: {:ok, :ok}
  end

  defmodule EchoAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:chat_messages, messages})

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

  describe "RuntimeContext harness-free profile" do
    setup do
      unique = System.unique_integer([:positive, :monotonic])
      bootstrap_dir = Path.join(System.tmp_dir!(), "fermix-harness-profile-boot-#{unique}")
      memory_dir = Path.join(System.tmp_dir!(), "fermix-harness-profile-mem-#{unique}")
      previous_bootstrap = Application.get_env(:fermix_core, :prompt_bootstrap, [])
      previous_memory = Application.get_env(:fermix_core, :memory, [])
      previous_harness = Application.get_env(:fermix_core, :harness)

      Application.put_env(:fermix_core, :prompt_bootstrap, bootstrap_dir: bootstrap_dir)

      Application.put_env(
        :fermix_core,
        :memory,
        Keyword.merge(previous_memory, prompt_base_dir: memory_dir, agent_id: "main")
      )

      # The catalog renders the harness category only when the feature is usable.
      Application.put_env(:fermix_core, :harness, enabled: true, approved: true)

      registry = :"harness_profile_reg_#{unique}"
      start_supervised!({CapabilityRegistry, name: registry})

      on_exit(fn ->
        Application.put_env(:fermix_core, :prompt_bootstrap, previous_bootstrap)
        Application.put_env(:fermix_core, :memory, previous_memory)
        restore_harness(previous_harness)
        FermixTestSupport.SafeRm.rm_rf!(bootstrap_dir)
        FermixTestSupport.SafeRm.rm_rf!(memory_dir)
      end)

      %{registry: registry}
    end

    test "the base profile carries the harness category; the harness-free one does not", %{
      registry: registry
    } do
      :ok = CapabilityRegistry.register(registry, cap("read_tool"))
      :ok = CapabilityRegistry.register(registry, cap("fake_run", category: :harness))

      assert {:ok, ctx} =
               RuntimeContext.build(
                 agent_id: "main",
                 available_skills: [],
                 capability_registry: registry
               )

      base = RuntimeContext.profile_for(ctx, :operator, registry, [])
      assert base.runtime_message.content =~ "### Coding Harness"
      assert base.runtime_message.content =~ "`fake_run`"
      assert "fake_run" in Enum.map(base.capabilities, & &1.name)

      client = RuntimeContext.profile_for(ctx, :operator, registry, harness_tools?: false)
      refute client.runtime_message.content =~ "### Coding Harness"
      refute client.runtime_message.content =~ "`fake_run`"
      # Prompt and wire from ONE list: the section and the schemas drop together.
      refute "fake_run" in Enum.map(client.capabilities, & &1.name)
      refute "fake_run" in Enum.map(client.dispatchable, & &1.name)
      # Only the harness family is affected.
      assert client.runtime_message.content =~ "`read_tool`"
      assert "read_tool" in Enum.map(client.capabilities, & &1.name)
    end

    test "a surface with no harness capability reuses the base profile", %{registry: registry} do
      :ok = CapabilityRegistry.register(registry, cap("read_tool"))

      assert {:ok, ctx} =
               RuntimeContext.build(
                 agent_id: "main",
                 available_skills: [],
                 capability_registry: registry
               )

      assert RuntimeContext.profile_for(ctx, :operator, registry, harness_tools?: false) ==
               ctx.operator_profile

      assert RuntimeContext.profile_for(ctx, :guest, registry, harness_tools?: false) ==
               ctx.guest_profile
    end
  end

  describe "TurnRunner profile selection by channel" do
    setup do
      unique = System.unique_integer([:positive, :monotonic])
      registry = :"harness_turn_reg_#{unique}"
      start_supervised!({CapabilityRegistry, name: registry})

      store =
        start_supervised!(
          {ConversationStore,
           name: :"harness_turn_store_#{unique}", max_messages: :infinity, repo: nil}
        )

      %{registry: registry, store: store}
    end

    test "an acp turn gets the harness-free section; a telegram turn gets the base one", %{
      registry: registry,
      store: store
    } do
      state = turn_state(registry, store)

      assert {:ok, "done", _tokens} =
               TurnRunner.run(message("acp"), state, fn _part -> :ok end)

      assert_receive {:chat_messages, acp_messages}
      assert contents(acp_messages) |> Enum.any?(&(&1 == "HARNESS FREE SECTION"))
      refute contents(acp_messages) |> Enum.any?(&(&1 == "BASE SECTION"))

      assert {:ok, "done", _tokens} =
               TurnRunner.run(message("telegram"), state, fn _part -> :ok end)

      assert_receive {:chat_messages, telegram_messages}
      assert contents(telegram_messages) |> Enum.any?(&(&1 == "BASE SECTION"))
      refute contents(telegram_messages) |> Enum.any?(&(&1 == "HARNESS FREE SECTION"))
    end
  end

  defp cap(name, opts \\ []) do
    Capability.new(%{
      name: name,
      description: "test #{name}",
      parameters: %{type: "object"},
      kind: :builtin,
      executor: {FakeMod, :execute, []},
      policy_class: Keyword.get(opts, :policy_class, :read_only),
      metadata: %{category: Keyword.get(opts, :category, :system)}
    })
  end

  defp message(channel) do
    %{
      channel: channel,
      chat_id: "harness_profile_#{channel}",
      sender: "user",
      content: "hi",
      source_trust: :operator
    }
  end

  defp contents(messages), do: Enum.map(messages, & &1.content)

  defp turn_state(registry, store) do
    %{
      adapter: EchoAdapter,
      adapter_opts: [model: "mock-model", test_pid: self()],
      provider: nil,
      adapter_overrides: [],
      capability_registry: registry,
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

  # Marker runtime messages make the SELECTION observable: whichever section
  # reaches the provider names the profile the turn ran on.
  defp runtime_context do
    %RuntimeContext{
      agent_id: "main",
      built_at_ms: 0,
      base_messages: [%{role: "system", content: "base prompt"}],
      stable_messages: [%{role: "system", content: "base prompt"}],
      volatile_messages: [],
      base_accounting: [],
      available_skills: [],
      operator_profile: profile(:operator, "BASE SECTION"),
      guest_profile: profile(:guest, "BASE SECTION"),
      harness_free_profiles: %{
        operator: profile(:operator, "HARNESS FREE SECTION"),
        guest: profile(:guest, "HARNESS FREE SECTION")
      }
    }
  end

  defp profile(trust, content) do
    %{
      trust: trust,
      capabilities: [],
      runtime_message: %{role: "system", content: content},
      runtime_accounting: %{part: :runtime}
    }
  end

  defp restore_harness(nil), do: Application.delete_env(:fermix_core, :harness)
  defp restore_harness(prior), do: Application.put_env(:fermix_core, :harness, prior)
end
