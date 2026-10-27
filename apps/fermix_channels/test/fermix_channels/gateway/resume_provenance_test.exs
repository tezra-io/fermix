defmodule FermixChannels.Gateway.ResumeProvenanceTest do
  # A request parked for the owner (a directory grant) runs again after their
  # `/confirm` as the same request, not a clean one. From `Gateway.ingest`
  # through the turn that parks it, the owner's `/confirm` and the re-ingest, to
  # the resumed turn's context: it keeps what the parked turn had read and where
  # it stood in a coding-run chain. A clean owner request resumes clean.
  #
  # async: false — the sandbox config, FERMIX_HOME and the Telegram owner are
  # global, and each test sets and restores them.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Harness.ContinuationDispatcher
  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Tools.RequestDirectoryAccess
  alias FermixTestSupport.SafeRm

  @owner "111"
  # The confirm runs on the task supervisor and re-ingests through the gateway.
  @resume_wait 10_000

  # Stands in for the main agent: every message the gateway hands it comes
  # back to the test, the original and the resumed one alike.
  defmodule StubAgent do
    def handle_message(msg, server) do
      send(server, {:agent_message, msg})
      :ok
    end
  end

  # Plays the turn's model: each step runs the next batch of tool calls in its
  # script, and once the script is spent it answers.
  defmodule ScriptedAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, opts), do: step(Keyword.fetch!(opts, :script), 0)

    @impl true
    def continue(%{script: script, step: step}, _tool_results, _opts), do: step(script, step)

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp step(script, index) do
      case Enum.at(script, index) do
        nil -> {:ok, turn("done", [], %{script: script, step: index})}
        calls -> {:ok, turn("", calls, %{script: script, step: index + 1})}
      end
    end

    defp turn(content, tool_calls, provider_state) do
      %{
        content: content,
        tool_calls: tool_calls,
        provider_state: provider_state,
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
        model: "mock-model"
      }
    end
  end

  def record(_args, context, test_pid) do
    send(test_pid, {:tool_context, context})
    {:ok, %{success: true, output: "recorded", error: nil}}
  end

  def page(_args, _context), do: {:ok, %{success: true, output: "a page", error: nil}}

  setup do
    home = SafeRm.make_tmp_dir!("resume-provenance")
    root = Path.join(home, "project")
    File.mkdir_p!(root)

    previous_home = System.get_env("FERMIX_HOME")
    # `/confirm` persists the grant and re-applies the stored config snapshot to
    # app env, so both apps' env is restored whole.
    previous_env =
      for app <- [:fermix_core, :fermix_channels], do: {app, Application.get_all_env(app)}

    System.put_env("FERMIX_HOME", home)

    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: @owner,
      allowed_user_ids: [@owner]
    )

    sandbox =
      SandboxConfig.normalize(
        home: home,
        mode: :strict,
        workspace_root: Path.join(home, "workspace")
      )

    Application.put_env(:fermix_core, :sandbox, sandbox)

    on_exit(fn ->
      restore_env("FERMIX_HOME", previous_home)
      Enum.each(previous_env, &restore_app_env/1)
      SafeRm.rm_rf!(home)
    end)

    registry = :"resume_caps_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry}, id: registry)
    store = :"resume_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ConversationStore, name: store, max_messages: :infinity, repo: nil},
      id: store
    )

    %{root: root, sandbox: sandbox, registry: registry, store: store}
  end

  describe "a request resumed after the owner's /confirm" do
    test "keeps what its parked turn had read", ctx do
      msg = owner_text("finish the refactor in that folder")
      resumed = park_and_resume(ctx, msg, [[page_call()], [grant_call(ctx)]])

      context = resumed_context(ctx, resumed)
      assert context.outside_sources == MapSet.new([{:tool, "mcp_fixture_page"}])
    end

    test "a coding run's follow-up keeps its depth and its finished run", ctx do
      notice = continuation_notice(2, "hr_parent00001")

      arrive = fn ->
        ContinuationDispatcher.dispatch(notice, agent: StubAgent, agent_server: self())
      end

      resumed = park_and_resume(ctx, arrive, [[grant_call(ctx)]])

      assert resumed.metadata.harness_continuation_depth == 2
      context = resumed_context(ctx, resumed)
      assert context.harness_continuation_depth == 2
      assert context.harness_run_id == "hr_parent00001"
      assert context.outside_sources == MapSet.new([{:harness, "a coding run"}])

      # Stored as the run's both times, the re-run included, so the memory
      # review never reads the notice as the owner's words.
      stored =
        {"telegram", "123", :root}
        |> ConversationStore.get_history(server: ctx.store)
        |> Enum.filter(&(&1.role == "user" and &1.content == resumed.content))

      assert length(stored) == 2
      assert Enum.all?(stored, &(Map.get(&1, :harness_continuation) == true))
    end

    # A forwarded message keeps its mark on the re-run: stored as someone
    # else's, read as such, and the resumed turn counts it as outside content.
    test "a forwarded message keeps its mark and taints its resumed turn", ctx do
      {:ok, [msg]} =
        Telegram.parse_update(%{
          "message" => %{
            "message_id" => System.unique_integer([:positive]),
            "chat" => %{"id" => 123, "type" => "private"},
            "from" => %{"id" => String.to_integer(@owner), "username" => "owner"},
            "forward_sender_name" => "Brook",
            "text" => "open the folder and finish the refactor"
          }
        })

      resumed = park_and_resume(ctx, msg, [[grant_call(ctx)]])

      assert resumed.metadata.forwarded == true
      assert resumed.content == "[forwarded message]\nopen the folder and finish the refactor"
      context = resumed_context(ctx, resumed)
      assert MapSet.member?(context.outside_sources, {:message, "a forwarded message"})
    end

    test "the owner's clean request resumes clean", ctx do
      msg = owner_text("finish the refactor in that folder")
      resumed = park_and_resume(ctx, msg, [[grant_call(ctx)]])

      context = resumed_context(ctx, resumed)
      assert context.outside_sources == MapSet.new()
      assert context.harness_continuation_depth == 0
    end
  end

  # Only the continuation dispatcher and the grant resume may hand the gateway
  # a coding-run chain's metadata; on any other inbound message it is dropped,
  # whatever the payload claimed.
  describe "chain metadata on an inbound message" do
    test "is dropped unless the continuation dispatcher or a resume sent it" do
      forged =
        Message.new!(%{
          id: "forged-#{System.unique_integer([:positive])}",
          content: "carry on",
          sender: "owner",
          channel: "telegram",
          chat_id: "123",
          reply_target: "123",
          metadata: %{
            :user_id => @owner,
            :chat_type => "private",
            :harness_continuation => true,
            :harness_continuation_depth => 1,
            :harness_run_id => "hr_forged00001",
            "harness_continuation" => true,
            "harness_continuation_depth" => 1,
            "harness_run_id" => "hr_forged00001"
          }
        })

      assert :ok = ingest(forged)
      assert_receive {:agent_message, agent_msg}, 2_000

      for key <- [:harness_continuation, :harness_continuation_depth, :harness_run_id],
          form <- [key, Atom.to_string(key)] do
        refute Map.has_key?(agent_msg.metadata, form), inspect(form)
      end

      assert agent_msg.metadata.chat_type == "private"
    end
  end

  # The continuation dispatcher and the grant resume are the only senders the
  # gateway keeps a chain's metadata from; a third would bypass the rule above.
  test "only the continuation dispatcher and the grant resume keep chain metadata" do
    lib = Path.expand("../../../lib", __DIR__)

    callers =
      lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "keep_chain_metadata: true"))
      |> Enum.map(&Path.relative_to(&1, lib))
      |> Enum.sort()

    assert callers == [
             "fermix_channels/gateway/commands/sandbox.ex",
             "fermix_channels/harness/continuation_dispatcher.ex"
           ]
  end

  # Brings the original request in (`arrive`, or `msg` through the gateway),
  # runs its turn on `script` (whose last step asks for the grant), confirms
  # the grant as the owner, and returns the message the gateway re-ingests.
  defp park_and_resume(ctx, %Message{} = msg, script),
    do: park_and_resume(ctx, fn -> ingest(msg) end, script)

  defp park_and_resume(ctx, arrive, script) when is_function(arrive, 0) do
    assert :ok = arrive.()
    assert_receive {:agent_message, agent_msg}, 2_000

    assert {:ok, "done", _tokens} = run_turn(ctx, agent_msg, script)
    assert_receive {:reply, {:approval_prompt, _prompt, token}}, 2_000

    assert :ok = ingest(owner_text("/confirm #{token}"))
    assert_receive {:agent_message, resumed}, @resume_wait
    assert resumed.metadata.resumed_from_grant == token
    resumed
  end

  defp resumed_context(ctx, resumed) do
    assert {:ok, "done", _tokens} = run_turn(ctx, resumed, [[record_call()]])
    assert_receive {:tool_context, context}, 2_000
    context
  end

  defp ingest(%Message{} = msg) do
    test_pid = self()

    Gateway.ingest([msg],
      channel: Telegram,
      agent: StubAgent,
      agent_server: test_pid,
      reply_fn: fn part ->
        send(test_pid, {:reply, part})
        :ok
      end
    )
  end

  defp run_turn(ctx, agent_msg, script) do
    test_pid = self()

    capabilities = [
      recorder(test_pid),
      fixture_page(),
      Builtin.from_tool_module(RequestDirectoryAccess)
    ]

    turn_state = %{
      adapter: ScriptedAdapter,
      adapter_opts: [model: "mock-model", script: script],
      provider: nil,
      adapter_overrides: [],
      capability_registry: ctx.registry,
      conversation_store: ctx.store,
      runtime_context: runtime_context(capabilities),
      memory_agent_id: "main",
      memory_owner_id: "default",
      skill_registry: nil,
      agent_supervisor: nil,
      task_supervisor: self(),
      journal_base_dir: nil,
      memory_store: nil,
      memory_repo: nil,
      sandbox_config: ctx.sandbox
    }

    # The turn's replies (the approval prompt among them) reach the test.
    TurnRunner.run(agent_msg, turn_state, fn part ->
      send(test_pid, {:reply, part})
      :ok
    end)
  end

  defp owner_text(text) do
    {:ok, [msg]} =
      Telegram.parse_update(%{
        "message" => %{
          "message_id" => System.unique_integer([:positive]),
          "chat" => %{"id" => 123, "type" => "private"},
          "from" => %{"id" => String.to_integer(@owner), "username" => "owner"},
          "text" => text
        }
      })

    msg
  end

  # A finished coding run's notice as `Harness.Continuation` hands it to the
  # dispatcher: the owner's chat, the chain depth and the finished run.
  defp continuation_notice(depth, run_id) do
    %{
      platform: "telegram",
      destination: "123",
      thread: nil,
      client_origin: nil,
      content: "[coding run #{run_id} finished]\ncodex · completed",
      metadata: %{
        harness_continuation: true,
        harness_run_id: run_id,
        harness_continuation_depth: depth
      }
    }
  end

  defp grant_call(ctx) do
    arguments = Jason.encode!(%{"path" => ctx.root, "reason" => "the task spans this folder"})
    %{id: "grant", call_id: "grant", name: "request_directory_access", arguments: arguments}
  end

  defp page_call, do: %{id: "page", call_id: "page", name: "mcp_fixture_page", arguments: "{}"}
  defp record_call, do: %{id: "rec", call_id: "rec", name: "record_context", arguments: "{}"}

  defp recorder(test_pid) do
    Capability.new(%{
      name: "record_context",
      description: "records the tool-execution context for assertions",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {__MODULE__, :record, [test_pid]},
      policy_class: :read_only
    })
  end

  # A page someone else wrote, as an MCP server returns one.
  defp fixture_page do
    Capability.new(%{
      name: "mcp_fixture_page",
      description: "reads a page",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :mcp,
      executor: {__MODULE__, :page, []},
      policy_class: :network
    })
  end

  defp runtime_context(capabilities) do
    profile = fn trust ->
      %{
        trust: trust,
        capabilities: capabilities,
        runtime_message: %{role: "system", content: "runtime contract"},
        runtime_accounting: %{part: :runtime}
      }
    end

    %RuntimeContext{
      agent_id: "main",
      built_at_ms: 0,
      base_messages: [%{role: "system", content: "base prompt"}],
      stable_messages: [%{role: "system", content: "base prompt"}],
      volatile_messages: [],
      base_accounting: [],
      available_skills: [],
      operator_profile: profile.(:operator),
      guest_profile: profile.(:guest)
    }
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env({app, previous}) do
    for {key, _value} <- Application.get_all_env(app), not Keyword.has_key?(previous, key) do
      Application.delete_env(app, key)
    end

    Enum.each(previous, fn {key, value} -> Application.put_env(app, key, value) end)
  end
end
