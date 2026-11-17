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
  alias FermixCore.Agents.RequestIdentity
  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Config, as: PhoneCallsConfig
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Tools.PhoneCall
  alias FermixCore.Tools.RequestDirectoryAccess
  alias FermixTestSupport.SafeRm

  @owner "111"
  @forged_request "req_0123456789abcdef01234567"
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @caller "+14155550142"
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

  # The per-call worker as the Manager starts one: it tells the test it was
  # started and dials nothing.
  defmodule IdleCall do
    use GenServer

    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def prompt_version, do: "phone-resume-1"
    def cancel(_pid, _why), do: :ok

    @impl true
    def init(args) do
      send(args.test_pid, {:worker_started, args.call_id})
      {:ok, args}
    end
  end

  # The real `phone_call` tool, with this test's manager, ledger, readiness and
  # clock in the context seams it reads.
  def phone_call(args, context, seams), do: PhoneCall.execute(args, Map.merge(context, seams))

  # A phone-call subtree of the test's own (manager, ledger), and the turn's
  # `phone_call` reaching it.
  defp phone_calls!(ctx) do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-resume-phone-#{unique}.db")
    repo = :"resume_phone_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &SafeRm.rm/1)
    end)

    manager = :"resume_phone_manager_#{unique}"
    config = fn -> %PhoneCallsConfig{enabled: true, voice: "marin", caller_number: @caller} end

    start_supervised!(
      {FermixCore.PhoneCalls.Supervisor,
       call_module: IdleCall,
       call_args: %{test_pid: self()},
       hangup: fn _session -> {:error, :never_hung_up_here} end,
       names: %{
         supervisor: :"resume_phone_sup_#{unique}",
         call_registry: :"resume_phone_calls_registry_#{unique}",
         handoff_supervisor: :"resume_phone_handoff_#{unique}",
         manager: manager,
         call_supervisor: :"resume_phone_calls_#{unique}",
         delivery_worker: :"resume_phone_delivery_#{unique}"
       },
       repo: repo,
       readiness: fn -> :ready end,
       config: config,
       now_fn: fn -> @t0 end,
       reconcile: false,
       timer_enabled: false}
    )

    Application.put_env(:fermix_core, :phone_calls,
      enabled: true,
      voice: "marin",
      caller_number: @caller
    )

    seams = %{
      memory_owner_id: "default",
      memory_repo: repo,
      phone_call_manager: manager,
      phone_call_readiness: fn -> :ready end,
      phone_call_config: config,
      phone_call_now: fn -> @t0 end
    }

    phone_call = %{
      Builtin.from_tool_module(PhoneCall)
      | executor: {__MODULE__, :phone_call, [seams]}
    }

    Map.merge(ctx, %{repo: repo, extra_capabilities: [phone_call]})
  end

  defp start_call do
    brief = %{
      "destination" => "+12125550101",
      "destination_kind" => "business",
      "number_source" => "The bistro's own website.",
      "contact_name" => "Calloway Bistro",
      "timezone" => "America/New_York",
      "goal" => "Ask for a table for two on Saturday, March 8, 2031 at 7:30 PM.",
      "completion_criteria" => ["The bistro confirms a table for two at 7:30 PM."]
    }

    arguments = Jason.encode!(%{"action" => "start", "brief" => brief})
    %{id: "call", call_id: "call", name: "phone_call", arguments: arguments}
  end

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
            :request_id => @forged_request,
            "harness_continuation" => true,
            "harness_continuation_depth" => 1,
            "harness_run_id" => "hr_forged00001",
            "request_id" => @forged_request
          }
        })

      assert :ok = ingest(forged)
      assert_receive {:agent_message, agent_msg}, 2_000

      for key <- [
            :harness_continuation,
            :harness_continuation_depth,
            :harness_run_id,
            :request_id
          ],
          form <- [key, Atom.to_string(key)] do
        refute Map.has_key?(agent_msg.metadata, form), inspect(form)
      end

      assert agent_msg.metadata.chat_type == "private"
    end

    # A request identity a payload claims is never the turn's: the gateway
    # drops it, so the turn mints its own.
    test "a forged request identity is ignored, and the turn is a request of its own", ctx do
      forged =
        Message.new!(%{
          id: "forged-#{System.unique_integer([:positive])}",
          content: "carry on",
          sender: "owner",
          channel: "telegram",
          chat_id: "123",
          reply_target: "123",
          metadata: %{:user_id => @owner, :chat_type => "private", :request_id => @forged_request}
        })

      assert :ok = ingest(forged)
      assert_receive {:agent_message, agent_msg}, 2_000
      context = resumed_context(ctx, agent_msg)
      assert RequestIdentity.valid?(context.request_id)
      refute context.request_id == @forged_request
    end
  end

  describe "the owner request a resume re-runs" do
    test "keeps the identity of the request that parked", ctx do
      msg = owner_text("finish the refactor in that folder")
      resumed = park_and_resume(ctx, msg, [[record_call()], [grant_call(ctx)]])
      assert_receive {:tool_context, parked}, 2_000
      assert RequestIdentity.valid?(parked.request_id)

      assert resumed.metadata.request_id == parked.request_id
      assert resumed_context(ctx, resumed).request_id == parked.request_id
    end

    # The review's case (M94 §06): a turn starts a call, then parks on a grant;
    # the call ends (nothing answered) before the owner's /confirm. The re-run
    # asks for the same call again, as the same request, and finds the call it
    # already made: no second call is placed.
    test "a call the parked request started is found again, and no second call is placed",
         ctx do
      ctx = phone_calls!(ctx)
      msg = owner_text("call the bistro and book a table, then finish the refactor")
      resumed = park_and_resume(ctx, msg, [[start_call()], [grant_call(ctx)]])

      assert_receive {:worker_started, call_id}, 2_000
      assert {:ok, [first]} = Ledger.list_recent("default", server: ctx.repo)
      assert first.id == call_id
      {:ok, _ended} = Ledger.fail_undispatched(call_id, "no_answer", @t0, server: ctx.repo)

      assert {:ok, "done", _tokens} = run_turn(ctx, resumed, [[start_call()]])

      refute_received {:worker_started, _second}
      assert {:ok, [only]} = Ledger.list_recent("default", server: ctx.repo)
      assert only.id == call_id
      assert only.request_id == first.request_id
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

    capabilities =
      [
        recorder(test_pid),
        fixture_page(),
        Builtin.from_tool_module(RequestDirectoryAccess)
      ] ++ Map.get(ctx, :extra_capabilities, [])

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
