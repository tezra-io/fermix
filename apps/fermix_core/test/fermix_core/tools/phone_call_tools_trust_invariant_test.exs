defmodule FermixCore.Tools.PhoneCallToolsTrustInvariantTest do
  # M94 §06, §07, §11 and §12, written as the whole-surface invariant the Known
  # Pitfalls section mandates: the phone-call family is read from
  # `PhoneCalls.Tools.modules/0`, never spelled out here, so a member
  # added later either joins every assertion below or fails one. The real
  # `BuiltinSeeder` registers `phone_call` alone; the in-call controls are in
  # no registry of any home, and a phone call's backend turn builds them.
  #
  # async: false — whether phone calls are on is the `:phone_calls`
  # application env a real turn reads, which each test establishes and
  # restores. Every name, number and id here is invented; numbers are 555-01XX.
  use ExUnit.Case, async: false

  alias FermixCore.Agents.PhoneCallTurn
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Home.Role
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Readiness
  alias FermixCore.PhoneCalls.Tools, as: PhoneCallTools
  alias FermixCore.Prompt.RuntimeSections
  alias FermixCore.Tools.PhoneCall

  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @caller "+14155550142"
  @call_id "pc_0a1b2c3d4e5f"
  @family_prefix "phone_call"

  @on [
    enabled: true,
    voice: "marin",
    caller_number: @caller,
    sip_username: "fermixtrunk01",
    sip_password: "invented-trunk-secret"
  ]

  @owner %{source_trust: :operator, computer_use_origin: :interactive, chat_type: "private"}

  @not_attended [
    {"guest turn", %{source_trust: :guest, computer_use_origin: :interactive}},
    {"scheduled job (no origin marker)", %{source_trust: :operator}},
    {"detached background run", %{source_trust: :operator, computer_use_origin: :unattended}},
    {"delegated worker",
     %{source_trust: :operator, computer_use_origin: :interactive, subagent_depth: 1}},
    {"skill worker",
     %{source_trust: :operator, computer_use_origin: :interactive, skill_depth: 1}},
    {"finished call's own result turn",
     %{
       source_trust: :operator,
       computer_use_origin: :interactive,
       harness_continuation_depth: 1,
       phone_call_result: @call_id
     }}
  ]

  # The call's worker as the in-call controls reach it, for the handle this
  # test's turn carries: tells the test what it was asked to do.
  defmodule InCallControls do
    def press_keys(call_id, "h-invented", keys) do
      send(:phone_call_invariant_test, {:pressed, call_id, keys})
      {:ok, %{confirmed: keys, unconfirmed: ""}}
    end

    def finish(call_id, "h-invented", reason, note) do
      send(:phone_call_invariant_test, {:finished, call_id, reason, note})
      :ok
    end
  end

  # A worker the Manager must never start here: a test that reached admission
  # is told, and nothing is dialed.
  defmodule NoCall do
    def start_link(_args) do
      send(:phone_call_invariant_test, :worker_started)
      {:error, :never_started_here}
    end

    def cancel(_pid, _why), do: :ok
    def prompt_version, do: "phone-invariant-1"
  end

  # A backend turn's model: names what it was offered, presses a key and
  # hangs up with the in-call controls, then answers.
  defmodule OfferedAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:offered, Enum.map(capabilities, & &1.name)})

      calls = [
        {"phone_call_press_keys", %{"keys" => "1"}},
        {"phone_call_end", %{"reason" => "done", "note" => "Asked about hours."}}
      ]

      tool_calls =
        for {{name, args}, index} <- Enum.with_index(calls) do
          id = "call_#{index}"
          %{id: id, call_id: id, name: name, arguments: Jason.encode!(args)}
        end

      {:ok, answer("", tool_calls)}
    end

    @impl true
    def continue(_state, results, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:control_results, results})
      {:ok, answer("They are open until ten.", [])}
    end

    defp answer(content, tool_calls) do
      %{
        content: content,
        tool_calls: tool_calls,
        provider_state: %{},
        usage: %{prompt_tokens: 10, completion_tokens: 2, total_tokens: 12},
        model: "mock-model"
      }
    end

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  setup do
    FermixTestSupport.NamedTest.register!(:phone_call_invariant_test)
    saved = Application.fetch_env(:fermix_core, :phone_calls)
    Application.put_env(:fermix_core, :phone_calls, [])

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:fermix_core, :phone_calls, value)
        :error -> Application.delete_env(:fermix_core, :phone_calls)
      end
    end)

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-invariant-#{unique}.db")
    repo = :"phone_invariant_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    names = subtree!(unique, repo)
    registry = :"phone_invariant_registry_#{unique}"
    start_supervised!({CapabilityRegistry, name: registry}, id: registry)
    :ignore = BuiltinSeeder.start_link(capability_registry: registry)

    %{repo: repo, names: names, registry: registry}
  end

  defp subtree!(unique, repo) do
    names = %{
      supervisor: :"phone_invariant_sup_#{unique}",
      call_registry: :"phone_invariant_calls_registry_#{unique}",
      handoff_supervisor: :"phone_invariant_handoff_#{unique}",
      manager: :"phone_invariant_manager_#{unique}",
      call_supervisor: :"phone_invariant_calls_#{unique}",
      delivery_worker: :"phone_invariant_delivery_#{unique}"
    }

    start_supervised!(
      {FermixCore.PhoneCalls.Supervisor,
       call_module: NoCall,
       hangup: fn _session -> {:error, :never_hung_up_here} end,
       names: names,
       repo: repo,
       now_fn: fn -> @t0 end,
       reconcile: false,
       timer_enabled: false}
    )

    names
  end

  defp family, do: PhoneCallTools.modules()
  defp controls, do: PhoneCallTools.control_names()

  # Every phone tool the seeded registry holds, which the family's assertions
  # read; only `phone_call` is ever there (`the family` below).
  defp seeded(ctx) do
    for tool <- family(),
        {:ok, capability} <- [CapabilityRegistry.find(ctx.registry, tool.name())],
        do: capability
  end

  # A registry as `BuiltinSeeder` fills one for a home with `env` as its
  # phone-call settings, every name it holds included.
  defp seeded_names(env) do
    Application.put_env(:fermix_core, :phone_calls, env)
    registry = :"phone_invariant_home_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry}, id: registry)
    :ignore = BuiltinSeeder.start_link(capability_registry: registry)
    registry |> CapabilityRegistry.list(include_hidden?: true) |> Enum.map(& &1.name)
  end

  # A turn's context as `TurnRunner` builds it, with this test's ledger and
  # manager in the two places a phone tool reads them.
  defp context(ctx, extra) do
    Map.merge(
      %{
        agent_name: "main",
        session_id: "main-invariant-#{System.unique_integer([:positive])}",
        conversation_key: {"telegram", "40017", :root},
        memory_owner_id: "default",
        memory_repo: ctx.repo,
        outside_sources: MapSet.new(),
        phone_call_manager: ctx.names.manager,
        phone_call_now: fn -> @t0 end
      },
      extra
    )
  end

  # A phone call's backend turn, as `Agents.PhoneCallTurn` hands its tools one.
  defp in_call(ctx) do
    context(ctx, %{
      agent_name: "phone_call",
      session_id: "phone_call_" <> @call_id,
      conversation_key: PhoneCallTurn.conversation_key(@call_id),
      source_trust: :phone_call,
      computer_use_origin: :unattended,
      phone_call: %{call_id: @call_id, handle: "h-invented", delegation_id: "d1"},
      phone_call_controls: FermixCore.PhoneCalls.CallControls
    })
  end

  defp advertised(ctx, context),
    do: ctx |> seeded() |> Advertisement.prepare(context) |> Enum.map(& &1.name) |> Enum.sort()

  defp brief_params do
    %{
      "destination" => "+12125550101",
      "destination_kind" => "business",
      "number_source" => "The bistro's own website.",
      "contact_name" => "Calloway Bistro",
      "timezone" => "America/New_York",
      "goal" => "Ask for a table for two on Saturday, March 8, 2031 at 7:30 PM.",
      "completion_criteria" => ["The bistro confirms a table for two at 7:30 PM."],
      "times" => [%{"label" => "Requested table", "at" => "2031-03-08T19:30"}]
    }
  end

  # Every action of every family member, as a model would ask for it.
  defp every_call do
    [
      {"phone_call", %{"action" => "start", "brief" => brief_params()}},
      {"phone_call", %{"action" => "status", "call_id" => @call_id}},
      {"phone_call", %{"action" => "cancel", "call_id" => @call_id}},
      {"phone_call_press_keys", %{"keys" => "1"}},
      {"phone_call_end", %{"reason" => "done", "note" => "Booked."}}
    ]
  end

  defp execute_each(context) do
    for {name, args} <- every_call() do
      tool = Enum.find(family(), &(&1.name() == name))
      assert {:ok, result} = tool.execute(args, context)
      {name, args["action"], result}
    end
  end

  defp nothing_happened!(ctx) do
    assert DynamicSupervisor.which_children(ctx.names.call_supervisor) == []
    assert {:ok, []} = Ledger.list_recent("default", server: ctx.repo)
    refute_received :worker_started
  end

  describe "the family" do
    test "every member is a built-in with an explicit classification" do
      coverage = BuiltinSeeder.builtin_tool_modules()

      for tool <- family() do
        assert tool in coverage, "#{tool.name()} is outside the seeder's coverage list"
        assert tool.name() in Builtin.classified_names()
        assert Builtin.owner_only_declared?(tool.name())
        assert %{kind: :builtin} = Builtin.from_tool_module(tool)
      end

      # The one registered member gates what it advertises; a control, held by
      # no registry, has no such hook to forget.
      assert function_exported?(PhoneCall, :advertise?, 1)

      for tool <- family(),
          tool.name() in controls(),
          do: refute(function_exported?(tool, :advertise?, 1), tool.name())
    end

    # The other direction: a phone tool seeded without joining the family would
    # sit outside every gate assertion here.
    test "no seeded built-in named for a phone call is missing from the family" do
      named =
        BuiltinSeeder.builtin_tool_modules()
        |> Enum.filter(&String.starts_with?(&1.name(), @family_prefix))
        |> Enum.sort()

      assert named == Enum.sort(family())
    end

    test "the seeder registers phone_call alone of the family, phone calls on or off", ctx do
      assert [%{name: "phone_call", kind: :builtin}] = seeded(ctx)

      for env <- [[], @on] do
        names = seeded_names(env)
        assert "phone_call" in names

        for control <- controls(),
            do: refute(control in names, "#{control} is in a seeded registry (#{inspect(env)})")
      end
    end
  end

  describe "phone calls off and no call on record" do
    test "an attended owner turn is offered no phone tool, and none of them acts", ctx do
      context = context(ctx, @owner)
      assert advertised(ctx, context) == []
      results = execute_each(context)

      for {name, action, result} <- results do
        refute result.success, "#{name} #{action} acted on an owner turn with phone calls off"
      end

      assert [{"phone_call", "start", start} | _rest] = results
      assert start.error =~ "turned off"
      nothing_happened!(ctx)
    end

    for {label, extra} <- @not_attended do
      test "a #{label} is offered no phone tool, and none of them acts", ctx do
        context = context(ctx, unquote(Macro.escape(extra)))
        assert advertised(ctx, context) == []

        for {name, action, result} <- execute_each(context) do
          refute result.success, "#{name} #{action} acted on a #{unquote(label)}"
        end

        nothing_happened!(ctx)
      end
    end

    test "the capability catalog names none of them", ctx do
      catalog = RuntimeSections.build([], capabilities: seeded(ctx))
      refute catalog =~ @family_prefix
    end
  end

  describe "phone calls off while a call holds the slot" do
    test "the owner keeps status and stop, and is never offered start", ctx do
      admit!(ctx.repo)
      # The Manager reads which call holds the slot when it boots, as after a
      # restart, and publishes it for a turn to read without asking it.
      :ok = Supervisor.terminate_child(ctx.names.supervisor, FermixCore.PhoneCalls.Manager)
      {:ok, _pid} = Supervisor.restart_child(ctx.names.supervisor, FermixCore.PhoneCalls.Manager)
      _booted = :sys.get_state(ctx.names.manager)
      Application.put_env(:fermix_core, :phone_calls, [])
      context = context(ctx, @owner)

      assert [phone_call] =
               ctx |> seeded() |> Advertisement.prepare(context) |> Enum.map(&{&1.name, &1})

      assert {"phone_call", capability} = phone_call
      assert capability.parameters.properties.action.enum == ["status", "cancel"]
      refute Map.has_key?(capability.parameters.properties, :brief)

      for {label, extra} <- @not_attended do
        assert advertised(ctx, context(ctx, extra)) == [], "offered on a #{label}"
      end
    end
  end

  describe "phone calls on and ready" do
    setup do
      Application.put_env(:fermix_core, :phone_calls, @on)
      :ok
    end

    test "phone_call is offered to an attended owner turn, with start", ctx do
      context = context(ctx, @owner)
      assert advertised(ctx, context) == ["phone_call"]

      [capability] = ctx |> seeded() |> Advertisement.prepare(context)
      assert "start" in capability.parameters.properties.action.enum
    end

    test "the in-call controls are offered to no owner turn at all", ctx do
      for extra <- [@owner, %{source_trust: :operator, computer_use_origin: :voice}] do
        advertised =
          ctx.registry
          |> CapabilityRegistry.list(include_hidden?: true)
          |> Advertisement.prepare(context(ctx, extra))
          |> Enum.map(& &1.name)

        for control <- controls() do
          refute control in advertised, "#{control} was offered on an owner turn"
        end
      end
    end

    for {label, extra} <- @not_attended do
      test "a #{label} is offered no phone tool", ctx do
        assert advertised(ctx, context(ctx, unquote(Macro.escape(extra)))) == []
      end
    end

    test "the capability catalog still names none of them", ctx do
      catalog = RuntimeSections.build([], capabilities: seeded(ctx))
      refute catalog =~ @family_prefix
    end
  end

  describe "inside a phone call's backend turn" do
    test "no registered phone tool is offered there, on or off", ctx do
      for env <- [[], @on] do
        Application.put_env(:fermix_core, :phone_calls, env)
        assert advertised(ctx, in_call(ctx)) == []
      end
    end

    test "the turn builds its controls, offers them with its grants, and runs them", ctx do
      {:ok, brief} =
        Brief.new(Map.put(brief_params(), "tool_grants", ["web_search"]),
          caller_number: @caller,
          now: @t0
        )

      turn = %{
        call_id: @call_id,
        handle: "h-invented",
        delegation_id: "d1",
        brief: brief,
        window: [%{speaker: :remote, text: "When do you close?", start_ms: 0, end_ms: 900}],
        session_id: "phone_call_" <> @call_id,
        max_steps: 3
      }

      test_pid = self()

      runtime = %{
        capability_registry: ctx.registry,
        loop: [adapter: OfferedAdapter, adapter_opts: [model: "mock-model", test_pid: test_pid]],
        tell: fn event -> send(test_pid, {:told, event}) end,
        now_fn: fn -> @t0 end,
        controls: InCallControls
      }

      for control <- controls(),
          do: assert(CapabilityRegistry.find(ctx.registry, control) == :error)

      assert {:ok, "They are open until ten.", 0} = PhoneCallTurn.run(turn, runtime)
      assert_received {:offered, offered}
      assert offered == controls() ++ ["web_search"]
      assert_received {:pressed, @call_id, "1"}
      assert_received {:finished, @call_id, :done, "Asked about hours."}
      assert_received {:control_results, results}
      refute Enum.any?(results, &(&1.output =~ "not available"))
      assert_received {:told, {:phone_call_reply, "They are open until ten.", _usage}}
    end
  end

  # The access gate decides `phone_call`'s start as an effect outside the
  # machine (`external_effect?`), never a host command: after outside content
  # (what an earlier call's status relayed) the owner's own turn asks the
  # owner, every turn that cannot ask is refused, a clean owner turn is the
  # owner's request, and checking or stopping a call never waits.
  describe "the access gate's own kind" do
    setup do
      Application.put_env(:fermix_core, :phone_calls, @on)
      :ok
    end

    test "start after outside content asks the owner, and where nobody can ask is refused",
         ctx do
      assert [capability] = seeded(ctx)
      assert capability.metadata.external_effect? == true
      refute Map.get(capability.metadata, :host_command?, false)

      relayed = UntrustedContent.outside_source(capability, %{"action" => "status"})
      start = %{"action" => "start", "brief" => brief_params()}

      tainted = fn extra ->
        context(ctx, Map.put(extra, :outside_sources, MapSet.new([relayed])))
      end

      # An owner's chat turn carries the gateway's reply and approval closures:
      # the surface the owner is asked on.
      owner_chat =
        Map.merge(@owner, %{
          reply_fn: fn _part -> :ok end,
          approval_fn: fn _request -> {:ok, "TOKEN-INV", :new} end
        })

      assert {:confirm, _surface} = AccessGate.decide(capability, tainted.(owner_chat), start)
      assert :dispatch = AccessGate.decide(capability, context(ctx, @owner), start)

      voice = %{
        source_trust: :operator,
        computer_use_origin: :voice,
        voice_call_id: "voice_live:7"
      }

      for {label, extra} <- [{"voice call", voice} | @not_attended] do
        assert {:refuse, _why} = AccessGate.decide(capability, tainted.(extra), start), label
      end

      for action <- ["status", "cancel"] do
        args = %{"action" => action, "call_id" => @call_id}

        assert {:dispatch, _context} = AccessGate.admit(capability, args, tainted.(owner_chat)),
               action
      end
    end
  end

  describe "start refused for the engine's own reason" do
    setup do
      Application.put_env(:fermix_core, :phone_calls, @on)
      :ok
    end

    test "a device-role engine refuses start, and never runs the phone subtree", ctx do
      readiness = fn ->
        Readiness.current(
          openai_api_key?: true,
          sip_password?: true,
          primary?: false,
          durable_memory?: true,
          call_backend?: true
        )
      end

      context = context(ctx, Map.put(@owner, :phone_call_readiness, readiness))

      {:ok, result} =
        PhoneCall.execute(%{"action" => "start", "brief" => brief_params()}, context)

      refute result.success
      assert result.error =~ Readiness.sentence(:not_primary)
      refute result.error =~ Readiness.sentence(:durable_memory_off)
      assert FermixCore.PhoneCalls.Supervisor in Role.primary_only()
      nothing_happened!(ctx)
    end

    test "a home with durable memory off refuses start", ctx do
      saved = Application.get_env(:fermix_core, :memory)
      Application.put_env(:fermix_core, :memory, Keyword.put(saved || [], :enabled, false))
      on_exit(fn -> Application.put_env(:fermix_core, :memory, saved) end)

      readiness = fn ->
        Readiness.current(
          openai_api_key?: true,
          sip_password?: true,
          primary?: true,
          call_backend?: true
        )
      end

      context = context(ctx, Map.put(@owner, :phone_call_readiness, readiness))

      {:ok, result} =
        PhoneCall.execute(%{"action" => "start", "brief" => brief_params()}, context)

      refute result.success
      assert result.error =~ Readiness.sentence(:durable_memory_off)
      refute result.error =~ Readiness.sentence(:not_primary)
      nothing_happened!(ctx)
    end
  end

  defp admit!(repo) do
    {:ok, brief} = Brief.new(brief_params(), caller_number: @caller, now: @t0)

    attrs = %{
      id: @call_id,
      request_id: "main-invariant-0",
      owner_id: "default",
      authorization: "direct",
      origin_kind: "chat",
      delivery_mode: "origin",
      platform: "telegram",
      destination: "40017",
      mandate: Brief.to_map(brief),
      mandate_hash: Brief.hash(brief),
      model: "gpt-live-1",
      voice: "marin",
      prompt_version: "phone-invariant-1",
      carrier_profile: "telnyx_credential_v1"
    }

    {:ok, {:admitted, _row}} = Ledger.admit(attrs, @t0, server: repo)
    :ok
  end
end
