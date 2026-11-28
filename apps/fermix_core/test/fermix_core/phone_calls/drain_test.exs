defmodule FermixCore.PhoneCalls.DrainTest do
  # An orderly stop of the engine (`FermixCore.Application.prep_stop/1`) drains
  # the call in progress: the real worker under the real Manager and subtree,
  # over the fakes (`FermixTestSupport.PhoneCallFakes`). async: false: the
  # fakes report to a registered sink. The drain's deadline goes through the
  # Manager's `:drain_schedule` seam, so the test delivers it by hand.
  # Nothing here can reach a network.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Call
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Manager
  alias FermixTestSupport.PhoneCallFakes, as: Fakes
  alias FermixTestSupport.TelemetryCapture

  # Every name, number and id here is invented.
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @session "sess_invented_drain"
  @closers [[:fermix, :phone_call, :run_complete], [:fermix, :phone_call, :run_error]]

  defmodule ShimCall do
    alias FermixCore.PhoneCalls.Call
    alias FermixTestSupport.PhoneCallFakes

    def start_link(args),
      do: Call.start_link(Map.merge(args, PhoneCallFakes.scripted(:seams, %{})))

    def cancel(pid, why), do: Call.cancel(pid, why)
    def prompt_version, do: "phone-test-1"
  end

  defmodule SinkDispatcher do
    def dispatch(notice), do: FermixTestSupport.PhoneCallFakes.notify({:dispatched, notice})
  end

  setup do
    Process.flag(:trap_exit, true)
    Fakes.register_sink!()
    start_supervised!(Fakes.script_spec())
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-drain-#{unique}.db")

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    repo = :"phone_drain_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    %{unique: unique, repo: repo, clock: :atomics.new(1, [])}
  end

  defp names(ctx) do
    %{
      supervisor: :"phone_drain_sup_#{ctx.unique}",
      call_registry: :"phone_drain_registry_#{ctx.unique}",
      handoff_supervisor: :"phone_drain_handoff_#{ctx.unique}",
      manager: :"phone_drain_manager_#{ctx.unique}",
      call_supervisor: :"phone_drain_calls_#{ctx.unique}",
      delivery_worker: :"phone_drain_delivery_#{ctx.unique}"
    }
  end

  defp subtree!(ctx, overrides \\ []) do
    Fakes.script(:seams, Fakes.seams(ctx.clock))
    test = self()

    opts =
      Keyword.merge(
        [
          call_module: ShimCall,
          hangup: fn session_id ->
            send(test, {:manager_hangup, session_id})
            :ok
          end,
          names: names(ctx),
          repo: ctx.repo,
          readiness: fn -> :ready end,
          config: &Fakes.config/0,
          now_fn: fn -> @t0 end,
          continuation_dispatcher: SinkDispatcher,
          drain_schedule: fn message, ms ->
            send(test, {:drain_deadline, message, ms})
            make_ref()
          end,
          timer_enabled: false
        ],
        overrides
      )

    start_supervised!({FermixCore.PhoneCalls.Supervisor, opts})
    names(ctx)
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
        caller_number: Fakes.caller(),
        now: @t0
      )

    %{
      brief: brief,
      brief_hash: Brief.hash(brief),
      request_id: "req-drain-#{System.unique_integer([:positive])}",
      parent_session: "main-drain-#{System.unique_integer([:positive])}",
      owner_id: "default",
      operation: "phone_call.start",
      authorization: "direct",
      snapshot: %{
        origin_kind: "chat",
        delivery_mode: "origin",
        platform: "telegram",
        destination: "40017",
        thread: nil,
        send_opts: nil,
        origin_conversation: ["telegram", "40017", "root"]
      }
    }
  end

  defp start_call!(names) do
    request = request()
    TelemetryCapture.attach(@closers, parent_session: request.parent_session)
    assert {:ok, %{call_id: id, reused: false}} = Manager.start_call(request, names.manager)
    assert_receive {:create, task, _create_request}
    [{worker, _value}] = Registry.lookup(names.call_registry, id)
    %{id: id, worker: worker, create: task, request_id: request.request_id}
  end

  defp live!(call) do
    Fakes.answer(
      call.create,
      {:ok, %{session_id: @session, http_status: 201, transport_type: "sip"}}
    )

    assert_receive {:attach, sideband, @session, _api_key}
    send(call.worker, {:phone_sideband, sideband, :attached})

    send(
      call.worker,
      {:phone_sideband, sideband, {:event, {:answered, %{session_id: @session, event_id: nil}}}}
    )

    # Nobody speaks within the opening's wait: the opening goes once.
    assert_receive {:scheduled, {:phone_call_timer, :opening, _token} = opening, _ms}
    send(call.worker, opening)
    assert_receive {:said, nil, _opening}
    Map.put(call, :sideband, sideband)
  end

  defp row!(repo, id) do
    {:ok, row} = Ledger.get(id, server: repo)
    row
  end

  defp drain_async(names), do: Task.async(fn -> Manager.drain(names.manager) end)

  test "with no call the drain answers at once, arms nothing, and admission stays closed", ctx do
    names = subtree!(ctx)

    assert :idle = Manager.drain(names.manager)
    refute_received {:drain_deadline, _message, _ms}
    assert {:error, :engine_stopping} = Manager.start_call(request(), names.manager)
    assert :ok = Manager.enable(names.manager)
    assert {:error, :engine_stopping} = Manager.start_call(request(), names.manager)
  end

  # Every application that can stop first drains (M94 §04), so the stop
  # reaches the drain more than once: the first drains, a later one answers
  # at once and arms nothing.
  test "the engine's stop drains once, and a later drain answers at once", ctx do
    names = subtree!(ctx)

    assert :idle = Manager.drain(names.manager)
    assert :already_drained = Manager.drain(names.manager)
    refute_received {:drain_deadline, _message, _ms}
  end

  test "after a drain that ran out of time, a later drain answers at once", ctx do
    names = subtree!(ctx)
    call = start_call!(names)

    drainer = drain_async(names)
    assert_receive {:drain_deadline, message, _ms}

    capture_log(fn ->
      send(GenServer.whereis(names.manager), message)
      assert {:timeout, [id]} = Task.await(drainer)
      assert id == call.id
    end)

    assert :already_drained = Manager.drain(names.manager)
    refute_received {:drain_deadline, _message, _ms}
  end

  test "an engine with no phone-call Manager has nothing to drain" do
    assert :idle = Manager.drain(:"phone_drain_absent_#{System.unique_integer([:positive])}")
  end

  test "a live call is hung up once and its terminal row written before the drain returns",
       ctx do
    names = subtree!(ctx)
    call = names |> start_call!() |> live!()

    drainer = drain_async(names)
    assert_receive {:drain_deadline, _message, ms}
    assert ms == Limits.shutdown_drain_ms()
    assert_receive {:hangup, _task, @session}

    closed = %{reason: "close_requested", seconds: 41.0, event_id: nil}
    send(call.worker, {:phone_sideband, call.sideband, {:event, {:session_closed, closed}}})

    assert :drained = Task.await(drainer)
    row = row!(ctx.repo, call.id)
    assert row.status == "ended"
    assert row.failure_reason == "engine_stopped"
    assert row.outcome == "unknown"
    assert row.outcome_facts["reason"] == "not_read"
    assert row.voice_seconds == 41
    refute_received {:hangup, _task, _again}
    refute_received {:manager_hangup, _session}
    refute_received {:extract, _entries, _facts, _opts}
    refute_received {:create, _task, _request}
  end

  test "a hangup that does not answer is waited for only the stop's own bound", ctx do
    Fakes.script(:hangup, :wait)
    names = subtree!(ctx)
    call = names |> start_call!() |> live!()

    drainer = drain_async(names)
    assert_receive {:hangup, _task, @session}

    assert_receive {:scheduled, {:phone_call_timer, :hangup_watchdog, _token} = watchdog, ms}
    assert ms == Limits.shutdown_hangup_wait_ms()
    send(call.worker, watchdog)

    assert_receive {:scheduled, {:phone_call_timer, :drain, _token} = drain, drain_ms}
    assert drain_ms == Limits.terminal_drain_ms()
    send(call.worker, drain)

    assert :drained = Task.await(drainer)
    row = row!(ctx.repo, call.id)
    assert row.status == "closure_unconfirmed"
    assert row.failure_reason =~ "engine_stopped"
    refute_received {:hangup, _task, _again}
  end

  test "a call still in its create request is left, at the bound, as the proof rules say",
       ctx do
    names = subtree!(ctx)
    call = start_call!(names)
    worker_ref = Process.monitor(call.worker)

    drainer = drain_async(names)
    assert_receive {:drain_deadline, message, _ms}
    manager = GenServer.whereis(names.manager)

    log =
      capture_log(fn ->
        send(manager, message)
        assert {:timeout, [id]} = Task.await(drainer)
        assert id == call.id
      end)

    assert log =~ "left for the next boot"
    assert Process.alive?(manager)
    assert row!(ctx.repo, call.id).status == "dispatching"

    # The tree's own shutdown then ends the worker: the stopping Manager leaves
    # its row for the next boot instead of settling it.
    assert {:monitored_by, monitors} = Process.info(call.worker, :monitored_by)
    assert self() in monitors
    Process.exit(call.worker, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, _worker, :killed}
    _state = :sys.get_state(manager)
    assert row!(ctx.repo, call.id).status == "dispatching"

    :ok = stop_supervised!(FermixCore.PhoneCalls.Supervisor)
    subtree!(ctx, reconcile: true)

    assert_receive {:telemetry, [:fermix, :phone_call, :run_error], _measurements, meta}
    assert meta.status == "dispatch_unknown"
    assert row!(ctx.repo, call.id).failure_reason == "engine_restarted"
    refute_received {:create, _task, _request}
  end

  test "the worker takes the engine's stop as its own reason" do
    assert :ok = Call.cancel(self(), :shutdown)
    assert_received {:"$gen_cast", {:cancel, :shutdown}}
  end
end
