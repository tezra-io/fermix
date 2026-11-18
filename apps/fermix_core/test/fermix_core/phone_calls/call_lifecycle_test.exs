defmodule FermixCore.PhoneCalls.CallLifecycleTest do
  # The worker under the real Manager and subtree, and the subtree's boot
  # paths. async: false: the fakes report to a registered sink, the shim
  # reads its seams from the registered script, and the boot cases establish
  # and restore the phone-call app env. Nothing here can reach a network.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Application, as: CoreApplication
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Call
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Manager
  alias FermixCore.PhoneCalls.Outcome
  alias FermixCore.PhoneCalls.Readiness
  alias FermixTestSupport.PhoneCallFakes, as: Fakes
  alias FermixTestSupport.TelemetryCapture

  # Every name, number and id here is invented.
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @session "sess_invented_7"
  @closers [[:fermix, :phone_call, :run_complete], [:fermix, :phone_call, :run_error]]

  # The real worker, started by the Manager with its own args plus the fakes.
  defmodule ShimCall do
    alias FermixCore.PhoneCalls.Call
    alias FermixTestSupport.PhoneCallFakes

    def start_link(args),
      do: Call.start_link(Map.merge(args, PhoneCallFakes.scripted(:seams, %{})))

    def cancel(pid, why), do: Call.cancel(pid, why)
    def prompt_version, do: "phone-test-1"
  end

  # A finished call's report goes here, never into a gateway.
  defmodule SinkDispatcher do
    def dispatch(notice) do
      FermixTestSupport.PhoneCallFakes.notify({:dispatched, notice})
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    Fakes.register_sink!()
    start_supervised!(Fakes.script_spec())
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-life-#{unique}.db")

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    saved = Application.fetch_env(:fermix_core, :phone_calls)
    Application.put_env(:fermix_core, :phone_calls, [])

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:fermix_core, :phone_calls, value)
        :error -> Application.delete_env(:fermix_core, :phone_calls)
      end
    end)

    %{unique: unique, db_path: db_path, clock: :atomics.new(1, [])}
  end

  defp names(ctx) do
    %{
      supervisor: :"phone_life_sup_#{ctx.unique}",
      call_registry: :"phone_life_registry_#{ctx.unique}",
      handoff_supervisor: :"phone_life_handoff_#{ctx.unique}",
      manager: :"phone_life_manager_#{ctx.unique}",
      call_supervisor: :"phone_life_calls_#{ctx.unique}",
      delivery_worker: :"phone_life_delivery_#{ctx.unique}"
    }
  end

  defp repo!(ctx, enabled?) do
    repo = :"phone_life_repo_#{ctx.unique}"

    start_supervised!(
      {Repo, name: repo, enabled: enabled?, database_path: ctx.db_path},
      id: repo
    )

    repo
  end

  # The subtree with the shim worker; the Manager's own cleanup is a fake.
  defp subtree!(ctx, repo, overrides \\ []) do
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
          repo: repo,
          readiness: fn -> :ready end,
          config: &Fakes.config/0,
          now_fn: fn -> @t0 end,
          continuation_dispatcher: SinkDispatcher,
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
      request_id: "req-life-#{System.unique_integer([:positive])}",
      parent_session: "main-life-#{System.unique_integer([:positive])}",
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
    # The worker registers in its own subtree's registry, never the app's.
    [{worker, _value}] = Registry.lookup(names.call_registry, id)
    assert Registry.lookup(FermixCore.PhoneCalls.CallRegistry, id) == []
    %{id: id, worker: worker, create: task}
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

  defp closer! do
    assert_receive {:telemetry, [:fermix, :phone_call, _closer], _measurements, meta}
    meta
  end

  # Kills the worker once the Manager's monitor is in place, as a crash would.
  defp kill!(call, names) do
    manager = GenServer.whereis(names.manager)
    assert {:monitored_by, monitors} = Process.info(call.worker, :monitored_by)
    assert manager in monitors
    Process.exit(call.worker, :kill)
  end

  # Another process does the kill, so the trigger waits until the target has
  # taken this monitor in.
  defp monitored!(pid) do
    ref = Process.monitor(pid)
    assert {:monitored_by, monitors} = Process.info(pid, :monitored_by)
    assert self() in monitors
    ref
  end

  # A second engine's subtree, under names of its own.
  defp second_names(ctx),
    do: Map.new(names(ctx), fn {key, name} -> {key, :"#{name}_second"} end)

  defp row!(repo, id) do
    {:ok, row} = Ledger.get(id, server: repo)
    row
  end

  describe "under the Manager" do
    test "a whole call: one create, the Manager writes its outcome and usage once", ctx do
      confirmed = %Outcome{
        outcome: :confirmed,
        facts: %{date: "2031-03-08", local_time: "19:30", timezone: "America/New_York"},
        excerpts: [%{speaker: :remote, text: "Booked for two.", start_ms: 1, end_ms: 2}]
      }

      Fakes.script(:extract, {:result, {:ok, confirmed}})
      repo = repo!(ctx, true)
      names = subtree!(ctx, repo)
      call = names |> start_call!() |> live!()

      closed = %{reason: "remote_hangup", seconds: 95.0, event_id: nil}
      send(call.worker, {:phone_sideband, call.sideband, {:event, {:session_closed, closed}}})

      meta = closer!()
      assert meta.status == "ended"
      row = row!(repo, call.id)
      assert row.outcome == "confirmed"
      assert row.voice_seconds == 95
      assert row.usage_state == "voice_duration_confirmed"
      assert row.provider_session_id == @session
      refute_received {:create, _task, _request}
      refute_received {:manager_hangup, _session}
    end

    test "killed while its create is in flight: dispatch_unknown, nothing sent again", ctx do
      repo = repo!(ctx, true)
      names = subtree!(ctx, repo)
      call = start_call!(names)
      task_ref = monitored!(call.create)

      capture_log(fn -> kill!(call, names) end)

      assert_receive {:DOWN, ^task_ref, :process, _task, :killed}
      assert closer!().status == "dispatch_unknown"
      assert DynamicSupervisor.which_children(names.call_supervisor) == []
      assert {:error, {:slot_held, holder}} = Manager.start_call(request(), names.manager)
      assert holder == call.id
      refute_received {:create, _task, _request}
      refute_received {:manager_hangup, _session}
    end

    test "killed while live: closure_unconfirmed and the Manager's one cleanup", ctx do
      repo = repo!(ctx, true)
      names = subtree!(ctx, repo)
      call = names |> start_call!() |> live!()

      capture_log(fn -> kill!(call, names) end)

      assert closer!().status == "closure_unconfirmed"
      assert_receive {:manager_hangup, @session}
      row = row!(repo, call.id)
      assert row.cleanup_attempts == 1
      assert row.outcome == "unknown"
      refute_received {:hangup, _task, _session}
      refute_received {:create, _task, _request}
    end

    # `session.closed` is on the row before the outcome is read, so a worker
    # lost after it leaves an end the Manager settles as ended, hanging up
    # nothing.
    test "killed while reading its outcome after session.closed: settled ended", ctx do
      Fakes.script(:extract, :wait)
      repo = repo!(ctx, true)
      names = subtree!(ctx, repo)
      call = names |> start_call!() |> live!()

      closed = %{reason: "remote_hangup", seconds: 30, event_id: nil}
      send(call.worker, {:phone_sideband, call.sideband, {:event, {:session_closed, closed}}})
      assert_receive {:extract, _entries, _facts, _opts}
      row = row!(repo, call.id)
      assert %DateTime{} = row.closed_at
      assert row.closure_reason == "remote_hangup"
      assert row.voice_seconds == 30

      capture_log(fn -> kill!(call, names) end)

      assert closer!().status == "ended"
      refute_received {:manager_hangup, _session}
      refute_received {:create, _task, _request}
    end

    test "one hangup for the session across the worker and the Manager", ctx do
      repo = repo!(ctx, true)
      names = subtree!(ctx, repo)
      call = names |> start_call!() |> live!()
      :atomics.add(ctx.clock, 1, 60_000)

      :ok = Call.cancel(call.worker, :owner)
      assert_receive {:hangup, _task, @session}
      assert_receive {:scheduled, {:phone_call_timer, :drain, _token}, _ms}

      # The worker hung up, then is lost before it reports.
      capture_log(fn -> kill!(call, names) end)

      assert closer!().status == "closure_unconfirmed"
      assert row!(repo, call.id).cleanup_attempts == 1
      refute_received {:manager_hangup, _session}
      refute_received {:hangup, _task, _session}
    end

    test "the off switch with a create in flight closes the session it returns, once", ctx do
      repo = repo!(ctx, true)
      names = subtree!(ctx, repo)
      call = start_call!(names)

      assert %{cancelled: 0, stopping: 1} = Manager.disable(names.manager)

      Fakes.answer(
        call.create,
        {:ok, %{session_id: @session, http_status: 201, transport_type: "sip"}}
      )

      assert_receive {:hangup, _task, @session}
      meta = closer!()
      assert meta.status == "closure_unconfirmed"
      assert row!(repo, call.id).failure_reason == "phone_calls_disabled"

      assert :ok = Manager.enable(names.manager)
      assert {:error, {:slot_held, _holder}} = Manager.start_call(request(), names.manager)
      refute_received {:create, _task, _request}
      refute_received {:attach, _sideband, _session, _key}
    end

    test "a Manager restart mid-call ends the worker and dials nothing again", ctx do
      repo = repo!(ctx, true)
      names = subtree!(ctx, repo, reconcile: true)
      call = names |> start_call!() |> live!()
      worker_ref = monitored!(call.worker)

      capture_log(fn ->
        Process.exit(GenServer.whereis(names.manager), :kill)
        assert_receive {:DOWN, ^worker_ref, :process, _worker, _reason}
        assert closer!().status == "closure_unconfirmed"
      end)

      assert_receive {:manager_hangup, @session}
      assert row!(repo, call.id).failure_reason == "engine_restarted"
      assert DynamicSupervisor.which_children(names.call_supervisor) == []
      refute_received {:create, _task, _request}
    end
  end

  describe "booting the subtree" do
    test "the app tree runs it with the worker, with phone calls off and memory off", _ctx do
      assert is_pid(Process.whereis(FermixCore.PhoneCalls.Manager))
      assert is_pid(Process.whereis(FermixCore.PhoneCalls.CallRegistry))
      assert Readiness.current() == :disabled
      assert {:error, :disabled} = Manager.start_call(request())
      refute_received {:create, _task, _request}
    end

    test "the production options name the worker and a one-attempt hangup", _ctx do
      opts = CoreApplication.phone_calls_opts()
      assert Keyword.fetch!(opts, :call_module) == Call
      assert is_function(Keyword.fetch!(opts, :hangup), 1)
      # `mix test` is never the home's daemon: the app tree's reconciliation
      # and timers stay dark, its transport refuses every call, and the test
      # build configures no backend.
      assert Keyword.fetch!(opts, :reconcile) == false
      assert Keyword.fetch!(opts, :timer_enabled) == false

      assert Keyword.fetch!(opts, :call_args) == %{
               transport_opts: [refused: :test_build],
               delegate: nil
             }

      assert {:error, {:not_sent, :test_build}} = Keyword.fetch!(opts, :hangup).(@session)
    end

    test "only the home's daemon reconciles, prunes and ticks", _ctx do
      for build <- [:prod, :dev, :test] do
        daemon = CoreApplication.phone_calls_opts(true, build)
        other = CoreApplication.phone_calls_opts(false, build)
        assert {daemon[:reconcile], daemon[:timer_enabled]} == {true, true}, "#{build}"
        assert {other[:reconcile], other[:timer_enabled]} == {false, false}, "#{build}"
      end
    end

    # A second engine process on the home (`fermix memory`, a supervised
    # `fermix setup`, a mix task) boots the tree with the composition root's
    # options for a process that is not the daemon, over the same ledger,
    # while the daemon's call is live.
    test "a second engine process on the same home leaves the daemon's live call alone", ctx do
      repo = repo!(ctx, true)
      names = subtree!(ctx, repo, reconcile: true)
      call = names |> start_call!() |> live!()
      live_row = row!(repo, call.id)
      assert live_row.status not in ["ended", "failed", "closure_unconfirmed"]
      test = self()
      second = second_names(ctx)

      opts =
        false
        |> CoreApplication.phone_calls_opts(:test)
        |> Keyword.merge(
          names: second,
          repo: repo,
          hangup: fn session_id ->
            send(test, {:second_engine_hangup, session_id})
            :ok
          end,
          readiness: fn -> :ready end,
          config: &Fakes.config/0,
          now_fn: fn -> @t0 end,
          continuation_dispatcher: SinkDispatcher
        )

      start_supervised!(
        Supervisor.child_spec({FermixCore.PhoneCalls.Supervisor, opts}, id: :second)
      )

      # The second Manager's boot has run once it answers.
      _state = :sys.get_state(GenServer.whereis(second.manager))

      assert row!(repo, call.id) == live_row
      assert Process.alive?(call.worker)
      refute_received {:second_engine_hangup, _session}
      refute_received {:manager_hangup, _session}
      refute_received {:hangup, _task, _session}
    end

    test "a fresh home with phone calls off and no rows: it boots and refuses a start", ctx do
      repo = repo!(ctx, true)

      opts =
        CoreApplication.phone_calls_opts()
        |> Keyword.merge(names: names(ctx), repo: repo, reconcile: true)

      start_supervised!({FermixCore.PhoneCalls.Supervisor, opts})

      assert {:error, :disabled} = Manager.start_call(request(), names(ctx).manager)
      assert {:ok, []} = Ledger.list_recent("default", server: repo)
      assert is_pid(GenServer.whereis(names(ctx).manager))
    end

    test "durable memory off: it boots, nothing crashes, and nothing can dial", ctx do
      repo = repo!(ctx, false)

      log =
        capture_log(fn ->
          names = subtree!(ctx, repo, reconcile: true)
          assert {:error, :disabled} = Manager.start_call(request(), names.manager)
          assert DynamicSupervisor.which_children(names.call_supervisor) == []
          assert is_pid(GenServer.whereis(names.manager))
        end)

      # A home with memory off has no ledger: the boot scans nothing and says so
      # once, at info (`manager_test.exs` reads that line), never as a failure.
      refute log =~ "scan failed"
      refute log =~ "prune failed"
      refute_received {:create, _task, _request}
    end
  end
end
