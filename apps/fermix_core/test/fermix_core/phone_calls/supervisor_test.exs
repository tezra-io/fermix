defmodule FermixCore.PhoneCalls.SupervisorTest do
  # async: false: the test-double worker reports to a registered name. Every
  # process of the subtree runs under names of this test's own.
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Manager
  alias FermixTestSupport.TelemetryCapture

  @sink :phone_supervisor_test_sink
  # Every name, number and id here is invented.
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @caller "+14155550142"

  defmodule FakeCall do
    use GenServer

    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def prompt_version, do: "phone-test-1"
    def cancel(_pid, _why), do: :ok
    def run(pid, fun), do: GenServer.call(pid, {:run, fun})

    @impl true
    def init(args) do
      send(:phone_supervisor_test_sink, {:started, args.call_id, self()})
      {:ok, args}
    end

    @impl true
    def handle_call({:run, fun}, _from, args), do: {:reply, fun.(args), args}
  end

  setup do
    FermixTestSupport.NamedTest.register!(@sink)
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-sup-#{unique}.db")
    repo = :"phone_sup_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    names = %{
      supervisor: :"phone_sup_#{unique}",
      call_registry: :"phone_sup_registry_#{unique}",
      handoff_supervisor: :"phone_sup_handoff_#{unique}",
      manager: :"phone_sup_manager_#{unique}",
      call_supervisor: :"phone_sup_calls_#{unique}",
      delivery_worker: :"phone_sup_delivery_#{unique}"
    }

    test = self()

    start_supervised!(
      {FermixCore.PhoneCalls.Supervisor,
       call_module: FakeCall,
       hangup: fn session_id ->
         send(test, {:hangup, session_id})
         :ok
       end,
       names: names,
       repo: repo,
       readiness: fn -> :ready end,
       config: fn -> %Config{enabled: true, voice: "marin", caller_number: @caller} end,
       now_fn: fn -> @t0 end,
       timer_enabled: false}
    )

    %{repo: repo, names: names}
  end

  defp request do
    {:ok, brief} =
      Brief.new(
        %{
          "destination" => "+12125550101",
          "destination_kind" => "business",
          "number_source" => "The bistro's own website.",
          "contact_name" => "Calloway Bistro",
          "timezone" => "America/New_York",
          "goal" => "Ask for a table for two on Saturday at 19:30.",
          "completion_criteria" => ["The host confirms a table for two at 19:30."]
        },
        caller_number: @caller,
        now: @t0
      )

    %{
      brief: brief,
      brief_hash: Brief.hash(brief),
      request_id: "req-sup-#{System.unique_integer([:positive])}",
      parent_session: "main-sup-#{System.unique_integer([:positive])}",
      owner_id: "default",
      operation: "phone_call.start",
      authorization: "direct",
      snapshot: %{
        origin_kind: "voice",
        delivery_mode: "channel",
        platform: "telegram",
        destination: "40017",
        thread: nil,
        send_opts: nil,
        origin_conversation: nil
      }
    }
  end

  test "the subtree refuses to start without a worker module or a hang-up" do
    assert_raise KeyError, fn -> FermixCore.PhoneCalls.Supervisor.start_link(hangup: & &1) end

    assert_raise KeyError, fn ->
      FermixCore.PhoneCalls.Supervisor.start_link(call_module: FakeCall)
    end
  end

  test "a Manager crash ends the live worker, and its successor settles the row, redialing nothing",
       ctx do
    request = request()

    TelemetryCapture.attach([[:fermix, :phone_call, :run_error]],
      parent_session: request.parent_session
    )

    assert {:ok, %{call_id: id}} = Manager.start_call(request, ctx.names.manager)
    assert_receive {:started, ^id, worker}
    {:ok, _row} = FakeCall.run(worker, &Ledger.claim_dispatch(&1.call_id, @t0, server: &1.repo))

    {:ok, _row} =
      FakeCall.run(worker, &Ledger.record_session(&1.call_id, "sess_sup_1", @t0, server: &1.repo))

    worker_ref = Process.monitor(worker)
    manager = GenServer.whereis(ctx.names.manager)
    Process.exit(manager, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
    assert_receive {:telemetry, [:fermix, :phone_call, :run_error], _measurements, meta}
    assert meta.status == "closure_unconfirmed"
    assert_receive {:hangup, "sess_sup_1"}

    assert {:ok, row} = Ledger.get(id, server: ctx.repo)
    assert row.failure_reason == "engine_restarted"
    refute_received {:started, _id, _pid}
    assert DynamicSupervisor.which_children(ctx.names.call_supervisor) == []
  end
end
