defmodule FermixCore.Tools.PhoneCallTest do
  # The tool is called through `execute/2` directly, against a stand-in
  # Manager process of the test's own, and through `Capability.execute/3` for
  # the access gate's half. Every global it reads is a context seam, and every
  # exec event assertion pins the test's own session id.
  use ExUnit.Case, async: true

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

    %{sid: sid, manager: manager, repo: repo}
  end

  defp enabled, do: %Config{enabled: true, voice: "marin", caller_number: @caller}
  defp disabled, do: %Config{enabled: false, voice: "marin", caller_number: @caller}

  defp owner_turn(ctx, extra \\ %{}) do
    Map.merge(
      %{
        agent_name: "main",
        session_id: ctx.sid,
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
      assert request.request_id == ctx.sid
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
      assert body["usage"]["carrier_charges"] == "unknown"

      other = owner_turn(ctx, %{memory_owner_id: "someone-else"})

      assert refusal(PhoneCall.execute(%{"action" => "status", "call_id" => call_id}, other)) =~
               "No phone call"
    end

    test "cancel asks the Manager to stop and reports stopping", ctx do
      body =
        decoded(
          PhoneCall.execute(
            %{"action" => "cancel", "call_id" => "pc_0a1b2c3d4e5f"},
            owner_turn(ctx)
          )
        )

      assert_receive {:cancel, "pc_0a1b2c3d4e5f", "default"}
      assert body["status"] == "stopping"
      assert body["detail"] =~ "does not undo"
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

    test "while off, offered only to check or stop a recent call, and never start", ctx do
      off = owner_turn(ctx, %{phone_call_config: &disabled/0})
      refute PhoneCall.advertise?(off)

      seed_call!(ctx, "default")
      assert PhoneCall.advertise?(off)

      later =
        owner_turn(ctx, %{
          phone_call_config: &disabled/0,
          phone_call_now: fn -> DateTime.add(@t0, 2, :day) end
        })

      refute PhoneCall.advertise?(later)

      assert %{properties: %{action: %{enum: ["status", "cancel"]}} = props} =
               PhoneCall.dynamic_parameters(off)

      refute Map.has_key?(props, :brief)

      assert %{properties: %{action: %{enum: ["start", "status", "cancel"]}}} =
               PhoneCall.dynamic_parameters(owner_turn(ctx))
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

    test "the built-in is an unconfined host command marked as a phone call", ctx do
      assert ctx.capability.metadata.host_command?
      refute ctx.capability.metadata.host_command_confined?
      assert ctx.capability.metadata.phone_call?
      assert ctx.capability.owner_only?
    end

    test "a start after outside content waits for the owner's confirmation of its brief", ctx do
      tainted =
        ctx |> owner_turn(Map.put(ctx.gate, :outside_sources, MapSet.new([{:tool, "web_fetch"}])))

      assert {:ok, %{success: false}} = Capability.execute(ctx.capability, start_args(), tainted)
      refute_received {:ran, _args}
      assert_received {:reply, {:approval_prompt, prompt, @token}}
      assert prompt =~ "Confirm phone_call?"
      assert prompt =~ "places a phone call from your number"
      assert prompt =~ "Brief: "
      assert prompt =~ "Calloway Bistro"
    end

    test "the owner's confirm runs exactly the parked call, once, labelled confirmed", ctx do
      tainted =
        owner_turn(ctx, Map.put(ctx.gate, :outside_sources, MapSet.new([{:tool, "web_fetch"}])))

      Capability.execute(ctx.capability, start_args(), tainted)
      assert_received {:approval, %{access_sensitive: intent}}
      refute_received {:ran, _args}

      assert {:ok, _text} = AccessGate.confirm(intent, ctx.gate.access_pending)
      assert_received {:ran, args}
      assert args == start_args()
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
    ToolTelemetry.exec("phone_call", context, true, 0)
    {:ok, %{success: true, output: "{}", error: nil}}
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
