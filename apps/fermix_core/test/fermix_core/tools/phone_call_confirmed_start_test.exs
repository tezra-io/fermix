defmodule FermixCore.Tools.PhoneCallConfirmedStartTest do
  # M94 §06: a start asked for after outside content waits for the owner, and
  # their yes runs the REAL `phone_call` tool from the gate's snapshot alone:
  # no stub executor, the real `PhoneCalls.Manager` and ledger, so the call is
  # admitted once, under the request that asked, recorded as confirmed. Only
  # the per-call worker is the test's, and it dials nothing. Every name, number
  # and id here is invented; numbers are 555-01XX.
  use ExUnit.Case, async: true

  alias FermixCore.Agents.RequestIdentity
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.Tools.PhoneCall

  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @caller "+14155550142"

  # The per-call worker as the Manager starts one: it tells the test it was
  # started, for which call, and dials nothing.
  defmodule IdleCall do
    use GenServer

    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def prompt_version, do: "phone-confirmed-1"
    def cancel(_pid, _why), do: :ok

    @impl true
    def init(args) do
      send(args.test_pid, {:worker_started, args.call_id})
      {:ok, args}
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-confirmed-#{unique}.db")
    repo = :"phone_confirmed_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    names = %{
      supervisor: :"phone_confirmed_sup_#{unique}",
      call_registry: :"phone_confirmed_calls_registry_#{unique}",
      handoff_supervisor: :"phone_confirmed_handoff_#{unique}",
      manager: :"phone_confirmed_manager_#{unique}",
      call_supervisor: :"phone_confirmed_calls_#{unique}",
      delivery_worker: :"phone_confirmed_delivery_#{unique}"
    }

    start_supervised!(
      {FermixCore.PhoneCalls.Supervisor,
       call_module: IdleCall,
       call_args: %{test_pid: self()},
       hangup: fn _session -> {:error, :never_hung_up_here} end,
       names: names,
       repo: repo,
       readiness: fn -> :ready end,
       config: &config/0,
       now_fn: fn -> @t0 end,
       reconcile: false,
       timer_enabled: false}
    )

    pending = :"phone_confirmed_pending_#{unique}"
    start_supervised!({Pending, name: pending}, id: pending)

    %{
      repo: repo,
      names: names,
      pending: pending,
      sid: "main-confirmed-#{unique}",
      request_id: RequestIdentity.mint()
    }
  end

  defp config, do: %Config{enabled: true, voice: "marin", caller_number: @caller}

  # The owner's attended chat turn, which had read a page someone else wrote,
  # with this test's manager, ledger and clock in the places the tool reads.
  defp tainted_turn(ctx) do
    test_pid = self()

    %{
      agent_name: "main",
      session_id: ctx.sid,
      request_id: ctx.request_id,
      conversation_key: {"telegram", "40017", :root},
      source_trust: :operator,
      computer_use_origin: :interactive,
      chat_type: "private",
      outside_sources: MapSet.new([{:tool, "web_fetch"}]),
      access_pending: ctx.pending,
      memory_owner_id: "default",
      memory_repo: ctx.repo,
      phone_call_manager: ctx.names.manager,
      phone_call_readiness: fn -> :ready end,
      phone_call_config: &config/0,
      phone_call_now: fn -> @t0 end,
      reply_fn: fn part -> send(test_pid, {:reply, part}) end,
      approval_fn: fn request ->
        send(test_pid, {:approval, request})
        {:ok, "TOKEN-CONFIRMED", :new}
      end
    }
  end

  defp start_args do
    %{
      "action" => "start",
      "brief" => %{
        "destination" => "+12125550101",
        "destination_kind" => "business",
        "number_source" => "The bistro's own website.",
        "contact_name" => "Calloway Bistro",
        "timezone" => "America/New_York",
        "goal" => "Ask for a table for two on Saturday, March 8, 2031 at 7:30 PM.",
        "completion_criteria" => ["The bistro confirms a table for two at 7:30 PM."]
      }
    }
  end

  test "the owner's yes runs the real tool from the snapshot: admitted once, confirmed", ctx do
    capability = Builtin.from_tool_module(PhoneCall)

    assert {:ok, %{success: false, access_waiting: true}} =
             Capability.execute(capability, start_args(), tainted_turn(ctx))

    assert_received {:approval, %{access_sensitive: intent}}
    refute_received {:worker_started, _call}
    assert {:ok, []} = Ledger.list_recent("default", server: ctx.repo)

    assert {:ok, line} = AccessGate.confirm(intent, ctx.pending)
    assert_receive {:worker_started, call_id}, 2_000

    assert line ==
             "The call was accepted as #{call_id}, and Fermix is placing it now. Its result " <>
               "will follow in the chat that asked for it."

    assert {:ok, [row]} = Ledger.list_recent("default", server: ctx.repo)
    assert row.id == call_id
    assert row.request_id == ctx.request_id
    assert row.parent_session == ctx.sid
    assert row.authorization == "confirmed"
    assert row.access_intent == intent
    assert row.destination == "40017"

    # The yes is spent: the same confirmation runs nothing again.
    assert {:error, _expired} = AccessGate.confirm(intent, ctx.pending)
    refute_received {:worker_started, _second}
    assert {:ok, [_one]} = Ledger.list_recent("default", server: ctx.repo)
  end
end
