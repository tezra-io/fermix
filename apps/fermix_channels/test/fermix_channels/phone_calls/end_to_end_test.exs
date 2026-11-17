defmodule FermixChannels.PhoneCalls.EndToEndTest do
  # One phone call through every real part (M94 §04-§11): the owner's chat
  # turn asks `phone_call` to start one, `PhoneCalls.Manager` admits it,
  # `PhoneCalls.Call` dials, attaches and listens, each delegation runs as a
  # backend turn through the real `PhoneCalls.Bridge`, gateway queue,
  # `TurnRunner` and `Agents.PhoneCallTurn` beside a registry the real
  # `BuiltinSeeder` filled, the turn's model presses keys and ends the call
  # with the real in-call tools, which the turn builds itself and no registry
  # holds, the outcome is read by the real
  # `PhoneCalls.Outcome` extraction, the Manager writes the end once, and the
  # report re-enters the owner's conversation through the real continuation
  # dispatcher and gateway as a turn that is not the owner's.
  #
  # What is not real is only what would leave the machine: the transport is
  # `FermixTestSupport.PhoneCallFakes`' (no network, no carrier, no key), every
  # model is a provider the test answers step by step, the ledger is a
  # database of the test's own, and timers are delivered by hand. async: false:
  # the fakes report to a registered sink. Every name, number and id here is
  # invented; numbers are 555-01XX.
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Queue
  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.CallControls
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Manager
  alias FermixCore.PhoneCalls.Tools, as: PhoneCallTools
  alias FermixCore.Temporal.Access
  alias FermixCore.Tools.PhoneCallEnd
  alias FermixCore.Tools.PhoneCallPressKeys
  alias FermixTestSupport.PhoneCallFakes, as: Fakes
  alias FermixTestSupport.TelemetryCapture

  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @session "sess_e2e_invented_1"
  @destination "+12125550101"
  # Waits that span several processes (a queue turn, a worker, a task): the
  # suite's named bound for those, never a sleep.
  @arrival 10_000

  @brief %{
    "destination" => @destination,
    "destination_kind" => "business",
    "number_source" => "The bistro's own website.",
    "contact_name" => "Calloway Bistro",
    "on_behalf_of" => "Rowan Tellis",
    "timezone" => "America/New_York",
    "goal" => "Reserve a table for two on Saturday, March 8, 2031 at 7:30 PM.",
    "completion_criteria" => [
      "The bistro confirms a table for two on March 8, 2031 at 7:30 PM.",
      "The name the reservation is under."
    ],
    "must_not_commit" => ["a deposit or card guarantee"],
    "shareable_facts" => [%{"label" => "Name for the reservation", "value" => "Rowan Tellis"}],
    "times" => [%{"label" => "Requested table", "at" => "2031-03-08T19:30"}]
  }

  @readback "A table for two on Saturday, March 8 at 7:30 PM, under Rowan Tellis"

  # --- the parts that would leave the machine, and the seams around them -------

  # Every model call of every turn asks the test what to answer: a list of
  # tool calls, or a reply.
  defmodule Provider do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, capabilities, opts),
      do: ask(opts, {:chat, messages, Enum.map(capabilities, & &1.name)})

    @impl true
    def continue(_state, results, opts), do: ask(opts, {:continue, results})

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp ask(opts, request) do
      send(Keyword.fetch!(opts, :test_pid), {:provider, self(), request})

      receive do
        {:provider_answer, {:tools, calls}} -> {:ok, turn("", tool_calls(calls))}
        {:provider_answer, {:reply, text}} -> {:ok, turn(text, [])}
      after
        10_000 -> {:error, :never_answered}
      end
    end

    defp tool_calls(calls) do
      Enum.map(calls, fn {name, args} ->
        id = "call_#{System.unique_integer([:positive])}"
        %{id: id, call_id: id, name: name, arguments: Jason.encode!(args)}
      end)
    end

    defp turn(content, tool_calls) do
      %{
        content: content,
        tool_calls: tool_calls,
        provider_state: %{},
        usage: %{prompt_tokens: 10, completion_tokens: 2, total_tokens: 12},
        model: "mock-model"
      }
    end
  end

  # The outcome extraction's one provider call, answered by the test.
  defmodule Extractor do
    def chat(messages, tools, _opts) do
      FermixTestSupport.PhoneCallFakes.notify({:extraction, self(), messages, tools})

      receive do
        {:extraction_answer, content} ->
          {:ok, %{content: content, tool_calls: [], provider_state: %{}, model: "gpt-test"}}
      after
        10_000 -> {:error, :never_answered}
      end
    end
  end

  # The real `PhoneCalls.Outcome`, with the extraction's route the test's.
  defmodule OutcomeShim do
    alias FermixCore.PhoneCalls.Outcome

    @route %{provider: :openai, model: "gpt-test", auth_mode: :api_key, base_url: "https://x"}

    def extract(brief, entries, facts, opts) do
      FermixTestSupport.PhoneCallFakes.notify({:extract, entries, facts})
      routes = [{@route, [adapter: FermixChannels.PhoneCalls.EndToEndTest.Extractor]}]
      Outcome.extract(brief, entries, facts, Keyword.put(opts, :routes, routes))
    end

    defdelegate to_report(outcome), to: Outcome
  end

  # The real `PhoneCalls.Bridge`, on the test's own queue.
  defmodule BridgeShim do
    @behaviour FermixCore.PhoneCalls.Delegate

    alias FermixChannels.PhoneCalls.Bridge
    alias FermixTestSupport.PhoneCallFakes

    @impl true
    def run(request) do
      Bridge.run(request,
        queue: PhoneCallFakes.scripted(:queue, nil),
        task_supervisor: PhoneCallFakes.scripted(:watchers, nil)
      )
    end

    @impl true
    def cancel(call_id, delegation_id),
      do: Bridge.cancel(call_id, delegation_id, queue: PhoneCallFakes.scripted(:queue, nil))
  end

  # The real worker, started by the Manager with its own args plus the seams.
  defmodule ShimCall do
    alias FermixCore.PhoneCalls.Call

    def start_link(args),
      do: Call.start_link(Map.merge(args, FermixTestSupport.PhoneCallFakes.scripted(:seams, %{})))

    def cancel(pid, why), do: Call.cancel(pid, why)
    def prompt_version, do: "phone-e2e-1"
  end

  # The real channels-side continuation dispatcher and gateway, with the
  # test's channel as the reply surface and the test's queue as the agent.
  defmodule Dispatcher do
    alias FermixChannels.Gateway
    alias FermixChannels.Harness.ContinuationDispatcher
    alias FermixTestSupport.PhoneCallFakes

    def dispatch(notice) do
      PhoneCallFakes.notify({:dispatched, notice})

      ContinuationDispatcher.dispatch(notice,
        agent_server: PhoneCallFakes.scripted(:queue, nil),
        ingest: fn messages, opts ->
          Gateway.ingest(
            messages,
            Keyword.put(opts, :channel, FermixChannels.PhoneCalls.EndToEndTest.Channel)
          )
        end
      )
    end
  end

  defmodule Channel do
    alias FermixChannels.Gateway.Message

    def build_text_reply(%Message{} = message) do
      fn text ->
        FermixTestSupport.PhoneCallFakes.notify({:channel_reply, message.id, text})
        :ok
      end
    end

    def build_media_reply(%Message{}), do: fn _media -> :ok end
  end

  # `MainAgent.checkout_turn_state/2` as the queue calls it: one snapshot for
  # every turn, the test's provider in it. It tells the test what it checked out.
  defmodule StubMainAgent do
    use GenServer

    def start_link(turn_state), do: GenServer.start_link(__MODULE__, turn_state)

    @impl true
    def init(turn_state), do: {:ok, turn_state}

    @impl true
    def handle_call({:checkout_turn_state, msg}, _from, turn_state) do
      FermixTestSupport.PhoneCallFakes.notify({:checkout, msg})
      {:reply, {:ok, turn_state, :hit}, turn_state}
    end
  end

  # The real `phone_call` tool, with the test's manager, readiness and clock
  # in the context seams it reads. Its gates, the access gate's included, are
  # the real ones.
  defmodule SeamedPhoneCall do
    alias FermixCore.Tools.PhoneCall

    def execute(args, context), do: PhoneCall.execute(args, seamed(context))
    def advertise?(context), do: PhoneCall.advertise?(seamed(context))
    def dynamic_parameters(context), do: PhoneCall.dynamic_parameters(seamed(context))

    defp seamed(context),
      do: Map.merge(context, FermixTestSupport.PhoneCallFakes.scripted(:tool_seams, %{}))
  end

  def record_context(_args, context) do
    Fakes.notify({:tool_context, context})
    {:ok, %{success: true, output: "recorded", error: nil}}
  end

  # --- setup --------------------------------------------------------------------

  setup do
    Process.flag(:trap_exit, true)
    Fakes.register_sink!()
    start_supervised!(Fakes.script_spec())
    unique = System.unique_integer([:positive])
    clock = :atomics.new(1, [])

    repo = repo!(unique)
    registry = :"phone_e2e_registry_#{unique}"
    start_supervised!({CapabilityRegistry, name: registry}, id: registry)
    :ignore = BuiltinSeeder.start_link(capability_registry: registry)

    store = :"phone_e2e_store_#{unique}"

    start_supervised!({ConversationStore, name: store, max_messages: :infinity, repo: nil},
      id: store
    )

    turns = start_supervised!({Task.Supervisor, []}, id: :phone_e2e_turns)
    watchers = start_supervised!({Task.Supervisor, []}, id: :phone_e2e_watchers)
    queue = queue!(unique, registry, store, turns)
    names = phone_calls!(unique, repo)

    Fakes.script(:queue, queue)
    Fakes.script(:watchers, watchers)

    Fakes.script(:tool_seams, %{
      phone_call_manager: names.manager,
      phone_call_readiness: fn -> :ready end,
      phone_call_config: &Fakes.config/0,
      phone_call_now: fn -> @t0 end
    })

    # The in-call tools reach the worker the way production does, through the
    # default call registry (`CallControls`), so the
    # worker registers there and not in this subtree's own.
    Fakes.script(
      :seams,
      Map.merge(Fakes.seams(clock), %{
        delegate: BridgeShim,
        outcome: OutcomeShim,
        registry: CallControls.registry_name()
      })
    )

    %{repo: repo, registry: registry, queue: queue, names: names, clock: clock}
  end

  defp repo!(unique) do
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-e2e-#{unique}.db")
    repo = :"phone_e2e_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    repo
  end

  defp queue!(unique, registry, store, turns) do
    turn_state = %{
      adapter: Provider,
      adapter_opts: [model: "mock-model", test_pid: self()],
      provider: nil,
      adapter_overrides: [],
      capability_registry: registry,
      conversation_store: store,
      runtime_context: runtime_context(),
      memory_agent_id: "main",
      memory_owner_id: "default",
      memory_review?: false,
      skill_registry: nil,
      agent_supervisor: nil,
      task_supervisor: turns,
      journal_base_dir: nil,
      memory_store: nil,
      memory_repo: nil,
      now_fn: fn -> @t0 end
    }

    agent = start_supervised!({StubMainAgent, turn_state}, id: :phone_e2e_main_agent)

    start_supervised!(
      {Queue,
       name: :"phone_e2e_queue_#{unique}",
       main_agent: agent,
       turn_runner: TurnRunner,
       task_supervisor: turns,
       conversation_store: store},
      id: :phone_e2e_queue
    )
  end

  defp phone_calls!(unique, repo) do
    names = %{
      supervisor: :"phone_e2e_sup_#{unique}",
      call_registry: :"phone_e2e_call_registry_#{unique}",
      handoff_supervisor: :"phone_e2e_handoff_#{unique}",
      manager: :"phone_e2e_manager_#{unique}",
      call_supervisor: :"phone_e2e_calls_#{unique}",
      delivery_worker: :"phone_e2e_delivery_#{unique}"
    }

    start_supervised!(
      {FermixCore.PhoneCalls.Supervisor,
       call_module: ShimCall,
       hangup: fn session_id ->
         Fakes.notify({:manager_hangup, session_id})
         :ok
       end,
       names: names,
       repo: repo,
       readiness: fn -> :ready end,
       config: &Fakes.config/0,
       now_fn: fn -> @t0 end,
       continuation_dispatcher: Dispatcher,
       reconcile: false,
       timer_enabled: false}
    )

    names
  end

  # The owner's cached context: the owner's tools are `phone_call` and one that
  # shows the test the context a turn's tools receive.
  defp runtime_context do
    phone_call = %{
      Builtin.from_tool_module(FermixCore.Tools.PhoneCall)
      | executor: {SeamedPhoneCall, :execute, []}
    }

    recorder =
      Capability.new(%{
        name: "record_context",
        description: "Shows the test the context a tool of this turn receives.",
        parameters: %{"type" => "object", "properties" => %{}},
        kind: :builtin,
        executor: {__MODULE__, :record_context, []},
        policy_class: :read_only
      })

    profile = fn trust ->
      %{
        trust: trust,
        capabilities: [phone_call, recorder],
        runtime_message: %{role: "system", content: "runtime contract"},
        runtime_accounting: %{part: :runtime}
      }
    end

    profiles = %{operator: profile.(:operator), guest: profile.(:guest)}

    %RuntimeContext{
      agent_id: "main",
      built_at_ms: 0,
      base_messages: [%{role: "system", content: "base prompt"}],
      stable_messages: [%{role: "system", content: "base prompt"}],
      volatile_messages: [],
      base_accounting: [],
      available_skills: [],
      operator_profile: profiles.operator,
      guest_profile: profiles.guest,
      harness_free_profiles: profiles
    }
  end

  # --- driving the call ------------------------------------------------------------

  # The owner types in their own terminal chat; the gateway authorizes it.
  defp owner_asks!(ctx, text) do
    message =
      struct!(Message, %{
        id: "owner-#{System.unique_integer([:positive])}",
        channel: "cli",
        chat_id: "cli",
        reply_target: "cli",
        sender: "local",
        content: text,
        metadata: %{}
      })

    assert :ok =
             Gateway.ingest([message], channel: Channel, agent: Queue, agent_server: ctx.queue)

    message.id
  end

  defp model_asked! do
    assert_receive {:provider, turn, request}, @arrival
    {turn, request}
  end

  defp answer(turn, answer), do: send(turn, {:provider_answer, answer})

  # The owner's turn starts the call; answers the call id and the create
  # request the worker sent.
  defp start_call!(ctx) do
    owner_asks!(ctx, "Please call Calloway Bistro and book us a table for Saturday at 7:30.")
    {turn, {:chat, _messages, tools}} = model_asked!()
    assert "phone_call" in tools
    answer(turn, {:tools, [{"phone_call", %{"action" => "start", "brief" => @brief}}]})

    assert_receive {:create, create, create_request}, @arrival
    {turn, {:continue, [result]}} = model_asked!()

    assert %{"call_id" => call_id, "status" => "accepted", "reused" => false} =
             Jason.decode!(result.output)

    answer(turn, {:reply, "I'm calling Calloway Bistro now."})
    assert_receive {:channel_reply, _owner_message, "I'm calling Calloway Bistro now."}, @arrival

    TelemetryCapture.attach(
      [
        [:fermix, :tool, :exec],
        [:fermix, :phone_call, :run_complete],
        [:fermix, :phone_call, :run_error]
      ],
      session_id: "phone_call_" <> call_id
    )

    %{id: call_id, create: create, create_request: create_request, clock: ctx.clock}
  end

  # The create answered, the sideband attached, the leg answered: the opening
  # line is said.
  defp connect!(call) do
    Fakes.answer(
      call.create,
      {:ok, %{session_id: @session, http_status: 201, transport_type: "sip"}}
    )

    assert_receive {:attach, sideband, @session, "sk-invented-phone-key"}, @arrival
    [{worker, _value}] = Registry.lookup(CallControls.registry_name(), call.id)
    worker_ref = Process.monitor(worker)

    send(worker, {:phone_sideband, sideband, :attached})
    event(worker, sideband, {:answered, %{session_id: @session, event_id: "evt_answered"}})
    assert_receive {:said, nil, _opening}, @arrival
    Map.merge(call, %{worker: worker, worker_ref: worker_ref, sideband: sideband})
  end

  defp event(worker, sideband, event),
    do: send(worker, {:phone_sideband, sideband, {:event, event}})

  defp heard(call, speaker, text, start_ms, end_ms) do
    fragment = %{
      speaker: speaker,
      text: text,
      start_ms: start_ms,
      end_ms: end_ms,
      event_id: "evt_t_#{start_ms}"
    }

    event(call.worker, call.sideband, {:transcript, fragment})
  end

  # The voice asks the backend for work: the delegation waits out its settle
  # window (delivered by hand), then its turn reaches the model. Answers the
  # turn and the handle the worker minted for it.
  defp delegation!(call, id) do
    delegation = %{id: id, target: "client", offset_ms: nil, event_id: "evt_#{id}"}
    event(call.worker, call.sideband, {:delegation, delegation})

    assert_receive {:scheduled, {:phone_call_timer, {:settle, ^id}, _token} = settle, _ms},
                   @arrival

    send(call.worker, settle)

    assert_receive {:checkout, %{channel: "phone_call", metadata: %{phone_call: turn}}}, @arrival
    assert turn.call_id == call.id and turn.delegation_id == id

    {model, {:chat, messages, tools}} = model_asked!()
    assert tools == PhoneCallTools.control_names()
    refute Enum.any?(messages, &(&1.content =~ "base prompt"))
    {model, turn.handle}
  end

  # The turn's reply is spoken: the call ends once it has been said.
  defp hang_up!(call, closed_reason) do
    assert_receive {:scheduled, {:phone_call_timer, :speech, _token} = speech, _ms}, @arrival
    # The clock is shared memory, not a message: every fragment this test sent
    # the worker is handled before the clock moves past the reply's last word.
    _state = :sys.get_state(call.worker)
    :atomics.put(call.clock, 1, 10_000)
    send(call.worker, speech)

    assert_receive {:hangup, _task, @session}, @arrival
    assert_receive {:scheduled, {:phone_call_timer, :drain, _token}, _ms}, @arrival
    closed = %{reason: closed_reason, seconds: 95, event_id: "evt_closed"}
    event(call.worker, call.sideband, {:session_closed, closed})
    assert_receive {:closed_by_worker, _sideband}, @arrival
  end

  defp extraction!(claim) do
    assert_receive {:extract, entries, %{answered: true, end_reason: :hangup}}, @arrival
    assert_receive {:extraction, extractor, [_system, user], []}, @arrival
    assert user.content =~ ~s(<untrusted_tool_result source="phone_call_transcript">)
    send(extractor, {:extraction_answer, Jason.encode!(claim)})
    entries
  end

  defp await_handoffs(ctx) do
    for pid <- Task.Supervisor.children(ctx.names.handoff_supervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @arrival
    end

    :ok
  end

  defp row!(ctx, call_id) do
    {:ok, row} = Ledger.get(call_id, server: ctx.repo)
    row
  end

  defp claim(overrides) do
    Map.merge(
      %{
        "outcome" => "confirmed",
        "commitment" => "completed",
        "confirmation_quote" => nil,
        "readback_quote" => nil,
        "criteria" => [],
        "facts" => [],
        "alternative" => nil,
        "corrections" => [],
        "options" => [],
        "reason_quote" => nil,
        "contradiction" => nil,
        "note" => nil
      },
      overrides
    )
  end

  defp exec_events do
    receive do
      {:telemetry, [:fermix, :tool, :exec], _measurements, meta} -> [meta | exec_events()]
    after
      0 -> []
    end
  end

  # --- the phases of a call ----------------------------------------------------------

  # An automated menu: the backend turn presses 1 with the real keypad tool.
  # Answers the handle the worker minted for that turn.
  defp menu!(call) do
    menu = "Thank you for calling Calloway Bistro. For reservations, press 1."
    heard(call, :remote, menu, 0, 3_000)
    {model, handle} = delegation!(call, "d1")
    answer(model, {:tools, [{"phone_call_press_keys", %{"keys" => "1"}}]})

    assert_receive {:dtmf, "1", key_event}, @arrival
    ack = %{key: "1", client_event_id: key_event, event_id: "evt_ack_1"}
    event(call.worker, call.sideband, {:dtmf_sent, ack})

    {model, {:continue, [pressed]}} = model_asked!()
    assert %{"confirmed" => "1", "unconfirmed" => ""} = Jason.decode!(pressed.output)
    answer(model, {:reply, "Pressed one for reservations."})
    assert_receive {:said, "d1", "Pressed one for reservations."}, @arrival
    handle
  end

  # A person answers; the assistant reads the booking back and hears a yes,
  # and the voice asks the backend to end the call.
  defp read_back!(call) do
    heard(call, :assistant, "Hi, I'm an AI assistant calling for Rowan Tellis.", 4_000, 6_000)
    heard(call, :remote, "Sure, what can I do for you?", 6_200, 8_000)
    heard(call, :assistant, @readback <> ". Is that booked?", 8_200, 12_000)
    heard(call, :remote, "Yes.", 12_300, 12_800)
    delegation!(call, "d2")
  end

  # A finished turn's handle, presented again while the next turn runs.
  defp stale_handle_refused!(call, handle) do
    stale = %{
      source_trust: :phone_call,
      phone_call: %{call_id: call.id, handle: handle, delegation_id: "d1"},
      phone_call_controls: CallControls,
      agent_name: "phone_call"
    }

    assert {:error, :stale_handle} = CallControls.press_keys(call.id, handle, "2")
    assert {:error, :stale_handle} = CallControls.finish(call.id, handle, :done, nil)

    assert {:ok, %{success: false, error: refused}} =
             PhoneCallPressKeys.execute(%{"keys" => "2"}, stale)

    assert refused =~ "stale_handle"

    assert {:ok, %{success: false}} =
             PhoneCallEnd.execute(%{"reason" => "done", "note" => ""}, stale)

    refute_received {:dtmf, "2", _event}
  end

  # The turn's model ends the call with the real end tool, then answers.
  defp end_call!(model, delegation_id, reason, note, reply) do
    answer(model, {:tools, [{"phone_call_end", %{"reason" => reason, "note" => note}}]})
    {model, {:continue, [ended]}} = model_asked!()
    assert %{"status" => "ending", "reason" => ^reason} = Jason.decode!(ended.output)
    answer(model, {:reply, reply})
    assert_receive {:said, ^delegation_id, ^reply}, @arrival
  end

  defp confirmed_claim do
    claim(%{
      "confirmation_quote" => "Yes",
      "readback_quote" => @readback,
      "criteria" => [
        %{"index" => 1, "quote" => "table for two on Saturday, March 8 at 7:30 PM"},
        %{"index" => 2, "quote" => "under Rowan Tellis"}
      ],
      "facts" => [
        %{"field" => "date", "value" => "2031-03-08", "quote" => "Saturday, March 8"},
        %{"field" => "local_time", "value" => "19:30", "quote" => "at 7:30 PM"}
      ]
    })
  end

  # The report's own turn in the owner's chat: it reads the report, is not
  # the owner's attended turn, and its `phone_call` start is refused.
  defp result_turn_cannot_call!(call) do
    {model, {:chat, messages, _tools}} = model_asked!()
    assert List.last(messages).content =~ "[phone call #{call.id}] The call ended."
    start = {"phone_call", %{"action" => "start", "brief" => @brief}}
    answer(model, {:tools, [{"record_context", %{}}, start]})

    assert_receive {:tool_context, result_turn}, @arrival
    refute Access.attended_operator_turn?(result_turn)
    assert result_turn.phone_call_result == call.id
    assert MapSet.member?(result_turn.outside_sources, UntrustedContent.phone_call_source())

    {model, {:continue, [_recorded, again]}} = model_asked!()
    assert again.output =~ "phone_call was not run"
    answer(model, {:reply, "The bistro confirmed your table for two on Saturday at 7:30 PM."})
    assert_receive {:channel_reply, _result_message, "The bistro confirmed" <> _rest}, @arrival
  end

  defp assert_confirmed_row!(row, notice) do
    assert row.status == "ended"
    assert row.outcome == "confirmed"
    assert row.provider_session_id == @session
    assert row.voice_seconds == 95
    assert row.usage_state == "voice_duration_confirmed"
    assert {row.core_turns, row.dtmf_keys, row.cleanup_attempts} == {2, 1, 1}
    assert row.report_status == "written"

    assert %{"date" => "2031-03-08", "local_time" => "19:30"} = row.outcome_facts
    assert row.outcome_facts["note"] == "Booked for two at 7:30 PM."

    assert [
             %{"speaker" => "assistant", "text" => @readback},
             %{"speaker" => "recipient", "text" => "Yes"} | _
           ] =
             row.evidence

    # The row keeps every excerpt; the notice shows each once, a piece of a
    # line already shown inside that line (`PhoneCalls.Report`).
    for %{"text" => text} <- row.evidence, do: assert(notice.content =~ text, text)
    assert notice.content =~ ~s(- the assistant: "#{hd(row.evidence)["text"]}")
  end

  # One exec event per model tool call, under each tool's own name and the
  # call's own session, carrying no number, key or note; and the one closer.
  defp assert_call_telemetry! do
    events = exec_events()
    assert Enum.map(events, & &1.tool) == ["phone_call_press_keys", "phone_call_end"]
    assert Enum.all?(events, &(&1.agent == "phone_call" and &1.success))
    assert [%{key_count: 1}, %{reason: "done"}] = events

    for meta <- events, value <- Map.values(meta), is_binary(value) do
      refute value =~ "5550101"
      refute value =~ "Booked for two"
    end

    assert_received {:telemetry, [:fermix, :phone_call, :run_complete], _m, closer}
    assert closer.status == "ended" and closer.outcome == "confirmed"
  end

  # --- the cases ----------------------------------------------------------------

  test "a confirmed call: one create, a menu and a read-back, and the row, evidence and report agree",
       ctx do
    call = ctx |> start_call!() |> connect!()
    assert call.create_request.destination == @destination
    assert call.create_request.trunk.caller_number == Fakes.caller()

    first_handle = menu!(call)
    {model, second_handle} = read_back!(call)
    refute second_handle == first_handle
    stale_handle_refused!(call, first_handle)

    end_call!(model, "d2", "done", "Booked for two at 7:30 PM.", "Thank you, goodbye.")
    heard(call, :assistant, "Thank you, goodbye.", 13_000, 14_000)
    hang_up!(call, "close_requested")
    entries = extraction!(confirmed_claim())
    assert "Yes." in Enum.map(entries, & &1.text)

    # The report re-enters the owner's chat as a turn of its own.
    assert_receive {:dispatched, notice}, @arrival
    assert notice.platform == "cli" and notice.destination == "cli"
    assert notice.metadata.phone_call_result == call.id
    assert notice.content =~ "[phone call #{call.id}] The call ended."
    assert notice.content =~ "Outcome: confirmed"
    assert notice.content =~ ~s(<untrusted_tool_result source="phone_call_recipient">)
    result_turn_cannot_call!(call)

    assert_receive {:DOWN, ref, :process, _worker, :normal}, @arrival
    assert ref == call.worker_ref
    :ok = await_handoffs(ctx)

    # The row is what the call proved, written once by the Manager, and the
    # owner's status read and the report say the same.
    assert_confirmed_row!(row!(ctx, call.id), notice)
    assert {:ok, view} = Manager.status(call.id, "default", repo: ctx.repo, now: @t0)
    assert view.outcome == "confirmed" and view.state == "ended"

    # Exactly one create, one hang-up, and nothing the Manager had to clean up.
    refute_received {:create, _task, _request}
    refute_received {:hangup, _task, _session}
    refute_received {:manager_hangup, _session}
    assert_call_telemetry!()
  end

  test "a call that needs the owner ends and asks, and nothing is dialed again", ctx do
    call = ctx |> start_call!() |> connect!()

    heard(call, :assistant, "Hi, I'm an AI assistant calling for Rowan Tellis.", 0, 2_000)

    heard(
      call,
      :remote,
      "We're full at 7:30. The only table that night is at 9:15 PM.",
      2_200,
      6_000
    )

    {model, _handle} = delegation!(call, "d1")

    note = "Only 9:15 PM is open that night; Rowan must decide."
    end_call!(model, "d1", "needs_owner", note, "Thank you. Rowan will follow up. Goodbye.")

    hang_up!(call, "close_requested")

    extraction!(
      claim(%{
        "outcome" => "options",
        "commitment" => "offered",
        "options" => [
          %{"value" => "9:15 PM on March 8", "quote" => "The only table that night is at 9:15 PM"}
        ]
      })
    )

    assert_receive {:dispatched, notice}, @arrival
    assert notice.content =~ "Outcome: needs_owner"
    assert notice.content =~ "Calling again is a new request."
    assert notice.content =~ note

    {model, {:chat, _messages, _tools}} = model_asked!()
    answer(model, {:reply, "The bistro only has 9:15 PM. Should I ask for that?"})
    assert_receive {:channel_reply, _result_message, "The bistro only has" <> _rest}, @arrival

    assert_receive {:DOWN, ref, :process, _worker, :normal}, @arrival
    assert ref == call.worker_ref
    :ok = await_handoffs(ctx)

    row = row!(ctx, call.id)
    assert row.status == "ended"
    assert row.outcome == "needs_owner"
    assert row.outcome_facts["note"] == note
    assert row.outcome_facts["options"] == ["9:15 PM on March 8"]
    assert row.report_status == "written"

    refute_received {:create, _task, _request}
    refute_received {:hangup, _task, _session}

    assert_received {:telemetry, [:fermix, :phone_call, :run_complete], _m,
                     %{outcome: "needs_owner"}}
  end
end
