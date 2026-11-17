defmodule FermixCore.Tools.PhoneCallTest do
  # The tool is called through `execute/2` directly, against a stand-in
  # Manager process of the test's own, and through `Capability.execute/3` for
  # the access gate's half. Every global it reads is a context seam, and every
  # exec event assertion pins the test's own session id.
  use ExUnit.Case, async: true

  alias FermixCore.Agents.RequestIdentity
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Manager
  alias FermixCore.PhoneCalls.Prompt
  alias FermixCore.PhoneCalls.Report
  alias FermixCore.Tools.PhoneCall
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry
  alias FermixTestSupport.TelemetryCapture

  # Every name, number and id here is invented.
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @caller "+14155550142"
  @token "TOKEN-PC"

  # A stand-in for `PhoneCalls.Manager`: it answers the two calls the tool
  # makes and tells the test what it was asked.
  defmodule StubManager do
    use GenServer

    def start_link({test, reply}), do: GenServer.start_link(__MODULE__, {test, reply})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:start_call, request}, _from, {test, reply} = state) do
      send(test, {:start_call, request})
      {:reply, reply, state}
    end

    def handle_call({:cancel, call_id, owner_id}, _from, {test, _reply} = state) do
      send(test, {:cancel, call_id, owner_id})
      {:reply, {:ok, :stopping}, state}
    end
  end

  # A worker no test here starts: the real Manager below only boots.
  defmodule NeverStarted do
    def start_link(_args), do: {:error, :never_started_here}
    def cancel(_pid, _why), do: :ok
    def prompt_version, do: "phone-test-1"
  end

  # A store that tells the test it was asked, and answers that it is off.
  defmodule TrapRepo do
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call(request, _from, test) do
      send(test, {:repo_asked, request})
      {:reply, {:error, :disabled}, test}
    end
  end

  setup do
    sid = "main-phone-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: sid)

    started = {:ok, %{call_id: "pc_0a1b2c3d4e5f", state: "admitted", reused: false}}
    manager = start_supervised!({StubManager, {self(), started}})

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-tool-#{unique}.db")
    repo = :"phone_tool_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{sid: sid, request_id: RequestIdentity.mint(), manager: manager, repo: repo}
  end

  defp enabled, do: %Config{enabled: true, voice: "marin", caller_number: @caller}
  defp disabled, do: %Config{enabled: false, voice: "marin", caller_number: @caller}

  defp owner_turn(ctx, extra \\ %{}) do
    Map.merge(
      %{
        agent_name: "main",
        session_id: ctx.sid,
        request_id: ctx.request_id,
        conversation_key: {"telegram", "40017", :root},
        source_trust: :operator,
        computer_use_origin: :interactive,
        chat_type: "private",
        outside_sources: MapSet.new(),
        memory_owner_id: "default",
        memory_repo: ctx.repo,
        phone_call_manager: ctx.manager,
        phone_call_readiness: fn -> :ready end,
        phone_call_config: &enabled/0,
        phone_call_now: fn -> @t0 end
      },
      extra
    )
  end

  defp brief(overrides) do
    Map.merge(
      %{
        "destination" => "+12125550101",
        "destination_kind" => "business",
        "number_source" => "The bistro's own website.",
        "contact_name" => "Calloway Bistro",
        "timezone" => "America/New_York",
        "goal" => "Ask for a table for two on Saturday at 19:30.",
        "completion_criteria" => ["The host confirms a table for two at 19:30."]
      },
      overrides
    )
  end

  defp start_args(overrides \\ %{}), do: %{"action" => "start", "brief" => brief(overrides)}

  defp decoded({:ok, %{success: true, output: output}}), do: Jason.decode!(output)
  defp refusal({:ok, %{success: false, error: error}}), do: error

  describe "start" do
    test "hands the Manager the brief and the server's own evidence; accepted, not answered",
         ctx do
      result = PhoneCall.execute(start_args(), owner_turn(ctx))

      assert_receive {:start_call, request}
      assert %Brief{contact_name: "Calloway Bistro", caller_number: @caller} = request.brief
      assert request.brief_hash == Brief.hash(request.brief)
      assert request.request_id == ctx.request_id
      assert request.parent_session == ctx.sid
      assert request.owner_id == "default"
      assert request.operation == "phone_call.start"
      assert request.authorization == "direct"
      assert request.snapshot.origin_kind == "chat"
      assert request.snapshot.destination == "40017"

      assert %{"call_id" => "pc_0a1b2c3d4e5f", "status" => "accepted", "state" => "admitted"} =
               body = decoded(result)

      assert body["detail"] =~ "has not been answered"
      assert body["detail"] =~ "comes back into this conversation"
    end

    test "a turn with no request identity of its own dials nothing", ctx do
      for request_id <- [nil, ctx.sid, "req_0a1b"] do
        turn = owner_turn(ctx, %{request_id: request_id})

        assert refusal(PhoneCall.execute(start_args(), turn)) =~
                 "no request identity to authorize a call"
      end

      refute_received {:start_call, _request}
    end

    test "a call the owner confirmed through the access gate is recorded as confirmed", ctx do
      context = owner_turn(ctx, %{access_gate: "confirmed", access_intent: "intent-41"})
      PhoneCall.execute(start_args(), context)

      assert_receive {:start_call, %{authorization: "confirmed", access_intent: "intent-41"}}
    end

    test "a voice turn's result goes to the owner's own inbox, frozen before admission", ctx do
      inbox = [owner_inbox: [jobs_config: [], configured_owners: %{"telegram" => "40017"}]]

      context =
        owner_turn(ctx, %{computer_use_origin: :voice, phone_call_snapshot_opts: inbox})

      body = decoded(PhoneCall.execute(start_args(), context))

      assert_receive {:start_call, %{snapshot: %{origin_kind: "voice", delivery_mode: "channel"}}}
      assert body["detail"] =~ "private inbox"
    end

    test "a voice turn with no owner inbox is refused before admission", ctx do
      none = [owner_inbox: [jobs_config: [], configured_owners: %{}]]

      context =
        owner_turn(ctx, %{computer_use_origin: :voice, phone_call_snapshot_opts: none})

      assert refusal(PhoneCall.execute(start_args(), context)) =~ "private chat"
      refute_received {:start_call, _request}
    end

    test "a private individual is refused, says why, and uses no attempt", ctx do
      text =
        refusal(
          PhoneCall.execute(
            start_args(%{"destination_kind" => "private_individual"}),
            owner_turn(ctx)
          )
        )

      assert text =~ "private"
      assert text =~ "no attempt was used"
      refute_received {:start_call, _request}
    end

    test "a brief carrying a server-owned field is refused, never taken as proof", ctx do
      text = refusal(PhoneCall.execute(start_args(%{"approved" => true}), owner_turn(ctx)))

      assert text =~ "server_owned_field"
      refute_received {:start_call, _request}
    end

    test "a missing brief, setup or switch is refused before the Manager", ctx do
      assert refusal(PhoneCall.execute(%{"action" => "start"}, owner_turn(ctx))) =~
               "brief: missing"

      needs =
        owner_turn(ctx, %{phone_call_readiness: fn -> {:needs_setup, [:sip_password_missing]} end})

      assert refusal(PhoneCall.execute(start_args(), needs)) =~
               "password of the Telnyx connection"

      off = owner_turn(ctx, %{phone_call_readiness: fn -> :disabled end})
      assert refusal(PhoneCall.execute(start_args(), off)) =~ "turned off"

      refute_received {:start_call, _request}
    end

    test "the Manager's refusal is named", ctx do
      held = {:error, {:slot_held, "pc_ffffffffffff"}}
      busy = start_supervised!({StubManager, {self(), held}}, id: :busy_manager)

      text =
        refusal(PhoneCall.execute(start_args(), owner_turn(ctx, %{phone_call_manager: busy})))

      assert text =~ "pc_ffffffffffff"
      assert text =~ "Nothing was dialed"
    end

    # What the owner reads once they confirmed a start (`AccessGate`) is read
    # from the start's own answer, so it is tested on that answer.
    test "the owner who confirmed a start reads its answer in words, never its JSON", ctx do
      {:ok, accepted} = PhoneCall.execute(start_args(), owner_turn(ctx))

      assert PhoneCall.confirmed(accepted) ==
               {:ok,
                "The call was accepted as pc_0a1b2c3d4e5f, and Fermix is placing it now. Its " <>
                  "result will follow in the chat that asked for it."}

      again = {:ok, %{call_id: "pc_0a1b2c3d4e5f", state: "ringing", reused: true}}
      reused = start_supervised!({StubManager, {self(), again}}, id: :reused_manager)

      {:ok, repeat} =
        PhoneCall.execute(start_args(), owner_turn(ctx, %{phone_call_manager: reused}))

      assert PhoneCall.confirmed(repeat) ==
               {:ok,
                "This request had already started call pc_0a1b2c3d4e5f; no second call was placed."}

      held = {:error, {:slot_held, "pc_ffffffffffff"}}
      busy = start_supervised!({StubManager, {self(), held}}, id: :taken_meanwhile)

      {:ok, refused} =
        PhoneCall.execute(start_args(), owner_turn(ctx, %{phone_call_manager: busy}))

      assert PhoneCall.confirmed(refused) == {:error, refused.error}
      assert refused.error =~ "Nothing was dialed"
    end

    test "a brief too large for the call's prompt is refused with its size and the bound", ctx do
      big = {:error, {:prompt_too_large, :input, 30_123}}
      large = start_supervised!({StubManager, {self(), big}}, id: :large_manager)

      text =
        refusal(PhoneCall.execute(start_args(), owner_turn(ctx, %{phone_call_manager: large})))

      assert text =~ "too long to give the call whole"
      assert text =~ "30123 bytes, past the #{Prompt.bounds().input}"
      assert text =~ "no attempt was used"
    end

    test "a start while Fermix is stopping is refused in words of its own", ctx do
      stopping =
        start_supervised!({StubManager, {self(), {:error, :engine_stopping}}}, id: :stopping)

      text =
        refusal(PhoneCall.execute(start_args(), owner_turn(ctx, %{phone_call_manager: stopping})))

      assert text =~ "Fermix is stopping"
      assert text =~ "Nothing was dialed"
    end
  end

  describe "the brief's schema" do
    # The brief's own fields: the struct's keys but the server's caller number.
    defp brief_fields,
      do: (Map.keys(Map.from_struct(Brief.__struct__())) -- [:caller_number]) |> Enum.sort()

    test "names exactly the brief's model-supplied fields, so the two cannot drift" do
      %{properties: %{brief: brief}} = PhoneCall.parameters()

      assert brief.properties |> Map.keys() |> Enum.sort() == brief_fields()
      assert brief.additionalProperties == false
    end

    test "requires exactly what the brief requires" do
      {:error, {:invalid_brief, problems}} =
        Brief.new(%{}, caller_number: @caller, now: @t0)

      missing = for {field, :missing} <- problems, do: Atom.to_string(field)
      %{properties: %{brief: brief}} = PhoneCall.parameters()

      assert Enum.sort(brief.required) == Enum.sort(missing)
    end

    test "states the brief's own bounds" do
      b = Brief.bounds()
      %{properties: %{brief: %{properties: p}}} = PhoneCall.parameters()

      assert p.goal.maxLength == b.goal_bytes
      assert p.contact_name.maxLength == b.contact_name_bytes
      assert p.on_behalf_of.maxLength == b.on_behalf_of_bytes
      assert p.number_source.maxLength == b.number_source_bytes
      assert p.timezone.maxLength == b.timezone_bytes
      assert p.opening_language.maxLength == b.language_bytes

      assert {p.completion_criteria.minItems, p.completion_criteria.maxItems} ==
               {1, b.completion_criteria}

      assert p.completion_criteria.items.maxLength == b.item_bytes
      assert p.must_not_commit.maxItems == b.list_items
      assert p.alternatives.maxItems == b.list_items
      assert p.shareable_facts.maxItems == b.shareable_facts
      assert p.shareable_facts.items.properties.label.maxLength == b.label_bytes
      assert p.shareable_facts.items.properties.value.maxLength == b.fact_value_bytes
      assert p.tool_grants.maxItems == b.tool_grants
      assert p.times.maxItems == b.times
      assert p.times.items.properties.label.maxLength == b.label_bytes
    end

    test "a brief naming whom the call is for reaches the Manager", ctx do
      PhoneCall.execute(start_args(%{"on_behalf_of" => "Ada Quill"}), owner_turn(ctx))
      assert_receive {:start_call, %{brief: %Brief{on_behalf_of: "Ada Quill"}}}
    end
  end

  describe "who may use it" do
    test "only the owner's attended, top-level turn", ctx do
      for extra <- [
            %{source_trust: :guest},
            %{subagent_depth: 1},
            %{skill_depth: 1},
            %{computer_use_origin: :unattended},
            %{harness_continuation_depth: 1},
            %{conversation_key: {:scheduled_job, "job_1", "run_1"}, computer_use_origin: nil}
          ] do
        for args <- [start_args(), %{"action" => "status", "call_id" => "pc_0a1b2c3d4e5f"}] do
          text = refusal(PhoneCall.execute(args, owner_turn(ctx, extra)))
          assert text =~ "only when the owner asks", inspect(extra)
        end
      end

      refute_received {:start_call, _request}
    end
  end

  describe "status and cancel" do
    test "status reads the owner's own call; another owner's is not found", ctx do
      call_id = seed_call!(ctx, "default")

      body =
        decoded(PhoneCall.execute(%{"action" => "status", "call_id" => call_id}, owner_turn(ctx)))

      assert body["call_id"] == call_id
      assert body["state"] == "admitted"
      # Not yet dialed, so it claims no charge.
      assert body["placed"] == "no"
      assert is_nil(body["usage"]["carrier_charges"])

      other = owner_turn(ctx, %{memory_owner_id: "someone-else"})

      assert refusal(PhoneCall.execute(%{"action" => "status", "call_id" => call_id}, other)) =~
               "No phone call"
    end

    # The stop's one sentence set (`PhoneCalls.Report`), the apps' too, by the
    # call's row as it reads after the stop.
    test "cancel asks the Manager to stop and says what happened at the call's stage", ctx do
      for {session, said} <- [
            {"sess_invented_tool_1", "Fermix asked OpenAI to end the call."},
            {nil, "The call is still being placed, so Fermix ends it as soon as OpenAI"}
          ] do
        id = seed_call!(ctx, "default")
        {:ok, _row} = Ledger.claim_dispatch(id, @t0, server: ctx.repo)
        if session, do: {:ok, _row} = Ledger.record_session(id, session, @t0, server: ctx.repo)

        body =
          decoded(PhoneCall.execute(%{"action" => "cancel", "call_id" => id}, owner_turn(ctx)))

        assert_receive {:cancel, ^id, "default"}
        assert body["status"] == "stopping"
        assert String.starts_with?(body["detail"], said), body["detail"]
        refute body["detail"] =~ "provider"
        # One call at a time: this one ends before the next is seeded.
        {:ok, _row} = Ledger.terminalize(id, "failed", %{ended_at: @t0}, server: ctx.repo)
      end
    end

    # A process that is not the home's running engine owns no worker of the
    # daemon's: the call is the running Fermix's, and is stopped there.
    test "cancel from a process that is not the running engine says where the call is", ctx do
      id = seed_call!(ctx, "default")
      {:ok, _row} = Ledger.claim_dispatch(id, @t0, server: ctx.repo)
      manager = boot_manager!(ctx, "elsewhere", daemon: false, reconcile: false)
      turn = owner_turn(ctx, %{phone_call_manager: manager})

      assert refusal(PhoneCall.execute(%{"action" => "cancel", "call_id" => id}, turn)) ==
               "That call belongs to the Fermix that is running, so it is stopped there."

      {:ok, row} = Ledger.get(id, server: ctx.repo)
      assert is_nil(row.cancel_requested_at)
    end

    # The Manager finds the call over; one whose end is unresolved says so and
    # names both ways out, as the apps' Stop says for it.
    test "cancel of an unresolved call says its end is unresolved, not that it ended", ctx do
      id = seed_unresolved!(ctx)
      manager = boot_manager!(ctx, "cancel")
      turn = owner_turn(ctx, %{phone_call_manager: manager, phone_call_now: fn -> @t0 end})

      text = refusal(PhoneCall.execute(%{"action" => "cancel", "call_id" => id}, turn))
      {:ok, row} = Ledger.get(id, server: ctx.repo)

      assert text == Report.stop_refusal(row, @t0)
      assert text =~ "whether it was placed is unknown"
      assert text =~ "It holds the call slot until it is confirmed ended"
      refute text =~ "already ended"
    end

    test "status and cancel need a call id and a known action", ctx do
      assert refusal(PhoneCall.execute(%{"action" => "status"}, owner_turn(ctx))) =~ "call_id"

      assert refusal(PhoneCall.execute(%{"action" => "redial"}, owner_turn(ctx))) =~
               "start, status or cancel"
    end
  end

  describe "telemetry" do
    test "one exec event per model call under the tool's name, refusals included", ctx do
      PhoneCall.execute(start_args(), owner_turn(ctx))

      assert_receive {:telemetry, [:fermix, :tool, :exec], _m,
                      %{tool: "phone_call", success: true} = meta}

      assert meta.action == "start"

      PhoneCall.execute(start_args(), owner_turn(ctx, %{source_trust: :guest}))

      assert_receive {:telemetry, [:fermix, :tool, :exec], _m,
                      %{tool: "phone_call", success: false}}

      refute_received {:telemetry, [:fermix, :tool, :exec], _m, _meta}
    end

    test "no number or brief reaches the exec metadata", ctx do
      PhoneCall.execute(start_args(), owner_turn(ctx))
      assert_receive {:telemetry, [:fermix, :tool, :exec], _m, meta}
      refute inspect(Map.drop(meta, [:output, :input])) =~ "555"
    end
  end

  describe "what the turn is offered" do
    test "advertised on the owner's attended turn while phone calls are on", ctx do
      assert PhoneCall.advertise?(owner_turn(ctx))
      refute PhoneCall.advertise?(owner_turn(ctx, %{source_trust: :guest}))
      refute PhoneCall.advertise?(owner_turn(ctx, %{harness_continuation_depth: 1}))
    end

    # Exactly while a call holds the one-call slot, as the Manager publishes
    # it at boot: an uncertain call holds it until its slot expires.
    test "while off, offered only while a call holds the slot, and never start", ctx do
      empty = boot_manager!(ctx, "empty")
      off = off_turn(ctx, empty, @t0)
      refute PhoneCall.advertise?(off)

      seed_unresolved!(ctx)
      held = boot_manager!(ctx, "held")
      assert PhoneCall.advertise?(off_turn(ctx, held, @t0))

      expires = DateTime.add(@t0, Limits.slot_hold_ms(), :millisecond)
      assert PhoneCall.advertise?(off_turn(ctx, held, DateTime.add(expires, -1, :second)))
      refute PhoneCall.advertise?(off_turn(ctx, held, expires))

      assert %{properties: %{action: %{enum: ["status", "cancel"]}} = props} =
               PhoneCall.dynamic_parameters(off)

      refute Map.has_key?(props, :brief)

      assert %{properties: %{action: %{enum: ["start", "status", "cancel"]}}} =
               PhoneCall.dynamic_parameters(owner_turn(ctx))
    end

    test "deciding whether to offer it never asks the store", ctx do
      {:ok, trap} = start_supervised({TrapRepo, self()})
      turn = owner_turn(ctx, %{phone_call_config: &disabled/0, memory_repo: trap})

      refute PhoneCall.advertise?(turn)
      assert PhoneCall.advertise?(owner_turn(ctx, %{memory_repo: trap}))
      refute_received {:repo_asked, _request}
    end
  end

  describe "the access gate" do
    setup ctx do
      registry = :"phone_caps_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: registry})
      pending = :"phone_pending_#{System.unique_integer([:positive])}"
      start_supervised!({Pending, name: pending})

      capability = %{Builtin.from_tool_module(PhoneCall) | executor: {__MODULE__, :ran, [self()]}}
      :ok = CapabilityRegistry.register(registry, capability)
      test = self()

      gate = %{
        capability_registry: registry,
        access_pending: pending,
        reply_fn: fn part -> send(test, {:reply, part}) end,
        approval_fn: fn request ->
          send(test, {:approval, request})
          {:ok, @token, :new}
        end
      }

      Map.merge(ctx, %{capability: capability, gate: gate})
    end

    test "the built-in is an effect outside the machine, never a host command", ctx do
      assert ctx.capability.metadata.external_effect?
      refute Map.has_key?(ctx.capability.metadata, :host_command?)
      assert AccessGate.gate_kind(ctx.capability, start_args()) == :external_effect
      assert ctx.capability.owner_only?
    end

    test "a start after outside content waits for the owner's confirmation of its brief", ctx do
      tainted =
        ctx |> owner_turn(Map.put(ctx.gate, :outside_sources, MapSet.new([{:tool, "web_fetch"}])))

      assert {:ok, %{success: false}} = Capability.execute(ctx.capability, start_args(), tainted)
      refute_received {:ran, _args}
      assert_received {:reply, {:approval_prompt, %{text: prompt, token: @token, ttl_s: 300}}}
      assert prompt =~ "Confirm phone_call? It places a phone call for you, from your number"
      assert prompt =~ ~s(\nTask: "Ask for a table for two on Saturday at 19:30."\n)
      assert prompt =~ ~s("Calloway Bistro")
    end

    test "the confirmation says what it dials, from which number, and that it places the call",
         ctx do
      tainted =
        owner_turn(ctx, Map.put(ctx.gate, :outside_sources, MapSet.new([{:tool, "web_fetch"}])))

      Capability.execute(ctx.capability, start_args(), tainted)
      assert_received {:reply, {:approval_prompt, %{text: prompt}}}

      assert prompt =~ ~s(\nCalls: +12125550101, "Calloway Bistro", a business\n)
      assert prompt =~ "\nFrom: #{@caller}, your number\n"
      assert String.ends_with?(prompt, "Once you confirm, Fermix places exactly this call.")
      refute prompt =~ "command"
    end

    test "a confirmation sent to the owner's inbox is marked as a call's", ctx do
      test = self()

      inbox = fn request ->
        send(test, {:inbox, request})
        {:ok, @token, :new}
      end

      gate =
        ctx.gate
        |> Map.delete(:approval_fn)
        |> Map.merge(%{
          owner_inbox_approval_fn: inbox,
          outside_sources: MapSet.new([{:tool, "web_fetch"}])
        })

      Capability.execute(ctx.capability, start_args(), owner_turn(ctx, gate))
      assert_received {:inbox, %{prompt: prompt, ttl_ms: 300_000} = request}
      assert request.after_confirm == "Once you confirm, Fermix places exactly this call."
      assert prompt =~ ~s(\nCalls: +12125550101, "Calloway Bistro", a business\n)
      refute_received {:ran, _args}
    end

    test "a brief granting a tool a call cannot use says so, and dials nothing", ctx do
      refusal = {:error, {:tools_not_grantable, [{"shell", :not_grantable}]}}
      refusing = start_supervised!({StubManager, {self(), refusal}}, id: :refusing_manager)
      args = start_args(%{"tool_grants" => ["shell"]})

      assert {:ok, %{success: false, error: error}} =
               PhoneCall.execute(args, owner_turn(ctx, %{phone_call_manager: refusing}))

      assert error =~ "grants tools a phone call cannot use (shell: not_grantable)"
      assert error =~ "Nothing was dialed and no attempt was used."
    end

    test "the owner's confirm runs exactly the parked call, once, labelled confirmed", ctx do
      tainted =
        owner_turn(ctx, Map.put(ctx.gate, :outside_sources, MapSet.new([{:tool, "web_fetch"}])))

      Capability.execute(ctx.capability, start_args(), tainted)
      assert_received {:approval, %{access_sensitive: intent}}
      refute_received {:ran, _args}

      assert {:ok, text} = AccessGate.confirm(intent, ctx.gate.access_pending)

      assert text ==
               "The call was accepted as pc_0a1b2c3d4e5f, and Fermix is placing it now. Its " <>
                 "result will follow in the chat that asked for it."

      assert_received {:ran, args}
      assert args == start_args()
      # Still the request that asked: the gate keeps its identity.
      assert_received {:ran_request, request_id}
      assert request_id == ctx.request_id
      assert {:error, _expired} = AccessGate.confirm(intent, ctx.gate.access_pending)
      refute_received {:ran, _again}
    end

    test "checking or stopping a call never waits, and a clean owner turn dials directly", ctx do
      tainted =
        owner_turn(ctx, Map.put(ctx.gate, :outside_sources, MapSet.new([{:tool, "web_fetch"}])))

      for args <- [
            %{"action" => "status", "call_id" => "pc_1"},
            %{"action" => "cancel", "call_id" => "pc_1"}
          ] do
        assert {:ok, %{success: true}} = Capability.execute(ctx.capability, args, tainted)
        assert_received {:ran, ^args}
      end

      clean = owner_turn(ctx, ctx.gate)
      assert {:ok, %{success: true}} = Capability.execute(ctx.capability, start_args(), clean)
      assert_received {:ran, _args}
      refute_received {:approval, _request}
    end

    test "a status relays what the person called said; starting or stopping does not", ctx do
      assert UntrustedContent.outside_source(ctx.capability, %{"action" => "status"}) ==
               {:tool, "phone_call"}

      assert is_nil(UntrustedContent.outside_source(ctx.capability, %{"action" => "start"}))
      assert is_nil(UntrustedContent.outside_source(ctx.capability, %{"action" => "cancel"}))
    end
  end

  # The access gate's stand-in executor: the run the gate let through.
  def ran(args, context, test) do
    send(test, {:ran, args})
    send(test, {:ran_request, Map.get(context, :request_id)})
    ToolTelemetry.exec("phone_call", context, true, 0)
    # A start's own answer, with the facts the owner's line after a confirm is
    # read from (`effect`).
    answer = %{call_id: "pc_0a1b2c3d4e5f", status: "accepted", state: "admitted", reused: false}
    facts = %{call_id: "pc_0a1b2c3d4e5f", reused: false}
    {:ok, %{success: true, output: Jason.encode!(answer), error: nil, effect: facts}}
  end

  defp off_turn(ctx, manager, now),
    do:
      owner_turn(ctx, %{
        phone_call_config: &disabled/0,
        phone_call_manager: manager,
        phone_call_now: fn -> now end
      })

  # A real Manager on this test's ledger, booted: its boot has read whether a
  # call holds the slot once `:sys.get_state/1` answers.
  defp boot_manager!(ctx, label, extra \\ []) do
    name = :"phone_tool_manager_#{label}_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Manager,
       name: name,
       call_module: NeverStarted,
       hangup: fn _session -> {:error, :never_hung_up_here} end,
       repo: ctx.repo,
       now_fn: fn -> @t0 end,
       timer_enabled: false}
      |> then(fn {module, opts} -> {module, Keyword.merge(opts, extra)} end),
      id: name
    )

    _booted = :sys.get_state(name)
    name
  end

  # A call whose dispatch answer was lost: terminal, uncertain, holding the
  # slot until its expiry.
  defp seed_unresolved!(ctx) do
    id = seed_call!(ctx, "default")
    {:ok, _row} = Ledger.claim_dispatch(id, @t0, server: ctx.repo)
    {:ok, _row} = Ledger.terminalize(id, "dispatch_unknown", %{ended_at: @t0}, server: ctx.repo)
    id
  end

  defp seed_call!(ctx, owner_id) do
    attrs = %{
      request_id: "main-seed-#{System.unique_integer([:positive])}",
      owner_id: owner_id,
      authorization: "direct",
      origin_kind: "chat",
      delivery_mode: "origin",
      platform: "telegram",
      destination: "40017",
      mandate: %{"contact_name" => "Calloway Bistro"},
      mandate_hash: String.duplicate("c3", 32),
      model: "gpt-live-1",
      voice: "marin",
      prompt_version: "phone-test-1",
      carrier_profile: "telnyx_credential_v1"
    }

    {:ok, {:admitted, row}} = Ledger.admit(attrs, @t0, server: ctx.repo)
    row.id
  end
end
