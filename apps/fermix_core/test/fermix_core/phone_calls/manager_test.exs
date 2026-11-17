defmodule FermixCore.PhoneCalls.ManagerTest do
  # async: false: the test-double worker and the stub dispatcher report to a
  # registered name the module's tests share. Every other process (Repo,
  # supervisors, Manager) is the test's own, and every clock is injected.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Manager
  alias FermixCore.PhoneCalls.Prompt
  alias FermixTestSupport.TelemetryCapture

  @sink :phone_manager_test_sink
  # Every name, number and id here is invented.
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @caller "+14155550142"
  @events [
    [:fermix, :phone_call, :run_start],
    [:fermix, :phone_call, :run_complete],
    [:fermix, :phone_call, :run_error]
  ]

  # The per-call worker as the Manager's contract defines it, and nothing more:
  # it announces its start, does what the test asks inside its own process,
  # and reports a stop request.
  defmodule FakeCall do
    use GenServer

    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def prompt_version, do: "phone-test-1"

    def cancel(pid, why) do
      send(pid, {:cancel, why})
      :ok
    end

    def run(pid, fun), do: GenServer.call(pid, {:run, fun})

    @impl true
    def init(args) do
      send(:phone_manager_test_sink, {:started, args.call_id, self(), args})
      {:ok, args}
    end

    @impl true
    def handle_call({:run, fun}, _from, args), do: {:reply, fun.(args), args}

    @impl true
    def handle_info({:cancel, why}, args) do
      send(:phone_manager_test_sink, {:cancel_asked, args.call_id, why})
      {:noreply, args}
    end
  end

  defmodule RefusingStart do
    def start_link(_args), do: {:error, :no_engine}
    def prompt_version, do: "phone-test-1"
    def cancel(_pid, _why), do: :ok
  end

  # A store that answers the ledger's requests with `{:error, :busy}` while
  # its script says so, then as an empty store would: the Repo's own reply
  # shapes, for the requests the Manager's boot and prune make.
  defmodule BusyStore do
    use GenServer

    def start_link(failures), do: GenServer.start_link(__MODULE__, failures)
    def heal(pid), do: GenServer.call(pid, :heal)

    @impl true
    def init(failures), do: {:ok, failures}

    @impl true
    def handle_call(:enabled?, _from, failures), do: {:reply, true, failures}
    def handle_call(:heal, _from, _failures), do: {:reply, :ok, %{}}

    def handle_call({:phone_calls, request}, _from, failures) do
      kind = elem(request, 0)

      if Map.get(failures, kind, false),
        do: {:reply, {:error, :busy}, failures},
        else: {:reply, ok(kind), failures}
    end

    defp ok(:prune), do: {:ok, %{deleted: 0, excerpts_cleared: 0}}
    defp ok(_list), do: {:ok, []}
  end

  # The test's own Repo behind a script: a phone-calls request of a kind the
  # script names takes the next step of it, every other request goes through.
  # `:busy` is an error the store gave; `:unrun` is the Repo turning a late
  # request away (`{:error, :repo_timeout}`); `:landed` runs it, then answers
  # as a caller that gave up on it sees.
  defmodule ScriptedStore do
    use GenServer

    def start_link({repo, script}), do: GenServer.start_link(__MODULE__, {repo, script})

    @impl true
    def init({repo, script}), do: {:ok, %{repo: repo, script: script}}

    @impl true
    def handle_call(message, _from, state) do
      kind = kind(message)

      case Map.get(state.script, kind, []) do
        [step | rest] ->
          {:reply, run(step, message, state),
           %{state | script: Map.put(state.script, kind, rest)}}

        [] ->
          {:reply, GenServer.call(state.repo, message), state}
      end
    end

    defp run(:busy, _message, _state), do: {:error, :busy}
    defp run(:unrun, _message, _state), do: {:error, :repo_timeout}

    defp run(:landed, message, state) do
      _ran = GenServer.call(state.repo, message)
      {:error, :repo_timeout}
    end

    defp kind({:with_deadline, _deadline, message}), do: kind(message)
    defp kind({:phone_calls, request}), do: elem(request, 0)
    defp kind(_other), do: :other
  end

  defmodule SinkDispatcher do
    def dispatch(notice) do
      send(:phone_manager_test_sink, {:dispatched, notice})
      :ok
    end
  end

  setup do
    Process.register(self(), @sink)
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-manager-#{unique}.db")
    repo = :"phone_manager_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, unique: unique}
  end

  defp start_manager(ctx, overrides \\ []) do
    names = %{
      handoff: :"phone_handoff_#{ctx.unique}",
      calls: :"phone_calls_sup_#{ctx.unique}",
      manager: :"phone_manager_#{ctx.unique}"
    }

    start_supervised!({Task.Supervisor, name: names.handoff})
    start_supervised!({FermixCore.PhoneCalls.CallSupervisor, name: names.calls})
    test = self()

    opts =
      Keyword.merge(
        [
          name: names.manager,
          call_module: FakeCall,
          hangup: fn session_id ->
            send(test, {:hangup, session_id})
            :ok
          end,
          repo: ctx.repo,
          call_supervisor: names.calls,
          handoff_supervisor: names.handoff,
          readiness: fn -> :ready end,
          config: fn -> %Config{enabled: true, voice: "marin", caller_number: @caller} end,
          now_fn: fn -> @t0 end,
          continuation_dispatcher: SinkDispatcher,
          timer_enabled: false
        ],
        overrides
      )

    start_supervised!({Manager, opts})
    Map.put(names, :pid, GenServer.whereis(names.manager))
  end

  # The recovery and memory-off lines are info: the suite's level is warning,
  # so the test raises it for itself and puts it back.
  defp info_logs! do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  defp brief!(overrides \\ %{}) do
    params =
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

    {:ok, brief} = Brief.new(params, caller_number: @caller, now: @t0)
    brief
  end

  # Every field at its bound, in a character the brief's text quotes twice, so
  # the rendered input passes the voice model's bound though each field is valid.
  defp oversized_brief! do
    bounds = Brief.bounds()
    text = fn bytes -> String.duplicate("\"", bytes) end

    brief!(%{
      "contact_name" => text.(bounds.contact_name_bytes),
      "number_source" => text.(bounds.number_source_bytes),
      "goal" => text.(bounds.goal_bytes),
      "completion_criteria" =>
        List.duplicate(text.(bounds.item_bytes), bounds.completion_criteria),
      "must_not_commit" => List.duplicate(text.(bounds.item_bytes), bounds.list_items),
      "alternatives" => List.duplicate(text.(bounds.item_bytes), bounds.list_items),
      "shareable_facts" =>
        List.duplicate(
          %{"label" => text.(bounds.label_bytes), "value" => text.(bounds.fact_value_bytes)},
          bounds.shareable_facts
        )
    })
  end

  defp request(overrides \\ %{}) do
    brief = brief!()

    Map.merge(
      %{
        brief: brief,
        brief_hash: Brief.hash(brief),
        request_id: "req-#{System.unique_integer([:positive])}",
        parent_session: "main-#{System.unique_integer([:positive])}",
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
      },
      overrides
    )
  end

  # Starts a call and waits for its worker, pinning its telemetry by request.
  defp start_call!(manager, overrides \\ %{}) do
    request = request(overrides)
    TelemetryCapture.attach(@events, parent_session: request.parent_session)

    assert {:ok, %{call_id: id, state: "admitted", reused: false}} =
             Manager.start_call(request, manager.manager)

    assert_receive {:started, ^id, pid, _args}
    assert_receive {:telemetry, [:fermix, :phone_call, :run_start], _measurements, _meta}
    %{id: id, pid: pid, request: request}
  end

  defp in_worker(call, fun), do: FakeCall.run(call.pid, fun)

  defp claim!(call), do: in_worker(call, &Ledger.claim_dispatch(&1.call_id, @t0, server: &1.repo))

  defp session!(call, session_id) do
    {:ok, _row} = claim!(call)
    in_worker(call, &Ledger.record_session(&1.call_id, session_id, @t0, server: &1.repo))
  end

  # Kills the worker once its monitor from the Manager is in place, the way a
  # crash would end it, and waits for the Manager's closer.
  defp kill!(call, manager) do
    assert {:monitored_by, monitors} = Process.info(call.pid, :monitored_by)
    assert manager.pid in monitors
    Process.exit(call.pid, :kill)
    assert_receive {:telemetry, [:fermix, :phone_call, closer], _measurements, meta}
    assert closer in [:run_complete, :run_error]
    meta
  end

  defp row!(ctx, id) do
    {:ok, row} = Ledger.get(id, server: ctx.repo)
    row
  end

  defp scripted!(ctx, script),
    do: start_supervised!({ScriptedStore, {ctx.repo, script}}, id: :scripted_store)

  # The retry timer's seam: the test is told each wait and delivers it by hand.
  defp scheduling(test) do
    fn message, ms ->
      send(test, {:scheduled, message, ms})
      make_ref()
    end
  end

  defp closure!(call, at) do
    in_worker(
      call,
      &Ledger.record_closure(
        &1.call_id,
        %{at: at, reason: "completed", voice_seconds: 93.6},
        server: &1.repo
      )
    )
  end

  @confirmed_report %{
    status: "ended",
    outcome: "confirmed",
    evidence: [%{speaker: "recipient", text: "Booked for two."}],
    voice_seconds: 30,
    usage_state: "voice_duration_confirmed"
  }

  describe "start_call/2" do
    test "admits, starts one temporary worker with the documented args, accepted locally", ctx do
      manager = start_manager(ctx)
      request = request()
      TelemetryCapture.attach(@events, parent_session: request.parent_session)

      assert {:ok, %{call_id: id, state: "admitted", reused: false}} =
               Manager.start_call(request, manager.manager)

      assert_receive {:started, ^id, _pid, args}
      assert args.manager == manager.pid
      assert args.repo == ctx.repo
      assert args.brief == request.brief
      assert args.session_id == "phone_call_" <> id
      assert args.parent_session == request.parent_session
      assert args.row.status == "admitted"
      assert is_function(args.now_fn, 0)

      assert_receive {:telemetry, [:fermix, :phone_call, :run_start], _measurements, meta}
      assert meta.call_id == id

      row = row!(ctx, id)
      assert row.mandate_hash == Brief.hash(request.brief)
      assert row.prompt_version == "phone-test-1"
      assert row.model == "gpt-live-1"
      assert row.voice == "marin"
      assert row.carrier_profile == "telnyx_credential_v1"
      assert is_nil(row.dispatch_claimed_at)

      # One child, started from the Manager's own `:temporary` spec; that it is
      # never restarted is the lost-worker cases' proof.
      assert [{:undefined, pid, :worker, [FakeCall]}] =
               DynamicSupervisor.which_children(manager.calls)

      assert is_pid(pid)
    end

    test "the same request answers its existing call and starts no second worker", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)

      assert {:ok, %{call_id: id, reused: true}} =
               Manager.start_call(call.request, manager.manager)

      assert id == call.id
      refute_received {:started, _id, _pid, _args}
    end

    test "a second request is refused while the first holds the slot", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)

      assert {:error, {:slot_held, holder}} = Manager.start_call(request(), manager.manager)
      assert holder == call.id
    end

    test "readiness is re-read on every start, and a refusal writes nothing", ctx do
      manager = start_manager(ctx, readiness: fn -> {:needs_setup, [:sip_password_missing]} end)

      assert {:error, {:needs_setup, [:sip_password_missing]}} =
               Manager.start_call(request(), manager.manager)

      assert {:ok, []} = Ledger.list_recent("default", server: ctx.repo)
    end

    test "a feature switched off refuses a caller holding an old tool list", ctx do
      manager = start_manager(ctx, readiness: fn -> :disabled end)
      assert {:error, :disabled} = Manager.start_call(request(), manager.manager)
    end

    test "server-owned evidence must be present and match the brief it authorized", ctx do
      manager = start_manager(ctx)
      other = brief!(%{"goal" => "Ask for a table for three."})

      assert {:error, {:authorization_evidence, :brief_hash}} =
               Manager.start_call(request(%{brief_hash: Brief.hash(other)}), manager.manager)

      assert {:error, {:authorization_evidence, :request_id}} =
               Manager.start_call(request(%{request_id: nil}), manager.manager)

      assert {:error, {:authorization_evidence, :parent_session}} =
               Manager.start_call(request(%{parent_session: nil}), manager.manager)

      assert {:error, {:authorization_evidence, :authorization}} =
               Manager.start_call(request(%{authorization: "model_says_yes"}), manager.manager)

      assert {:ok, []} = Ledger.list_recent("default", server: ctx.repo)
    end

    test "a brief too large for the call's prompt is refused before any row or attempt", ctx do
      manager = start_manager(ctx)
      big = oversized_brief!()

      assert {:error, {:prompt_too_large, :input, bytes}} =
               Manager.start_call(
                 request(%{brief: big, brief_hash: Brief.hash(big)}),
                 manager.manager
               )

      assert bytes > Prompt.bounds().input
      assert {:ok, []} = Ledger.list_recent("default", server: ctx.repo)
      refute_received {:started, _id, _pid, _args}
    end

    test "a brief granting a tool a call cannot use is refused before any row or attempt", ctx do
      manager = start_manager(ctx)
      greedy = brief!(%{"tool_grants" => ["web_search", "shell", "phone_call"]})

      assert {:error,
              {:tools_not_grantable, [{"shell", :not_grantable}, {"phone_call", :places_calls}]}} =
               Manager.start_call(
                 request(%{brief: greedy, brief_hash: Brief.hash(greedy)}),
                 manager.manager
               )

      assert {:ok, []} = Ledger.list_recent("default", server: ctx.repo)
      refute_received {:started, _id, _pid, _args}

      granted = brief!(%{"tool_grants" => ["web_search"]})

      assert {:ok, %{reused: false}} =
               Manager.start_call(
                 request(%{brief: granted, brief_hash: Brief.hash(granted)}),
                 manager.manager
               )
    end

    test "a worker that cannot start leaves a failed row with nothing dialed", ctx do
      manager = start_manager(ctx, call_module: RefusingStart)
      request = request()
      TelemetryCapture.attach(@events, parent_session: request.parent_session)

      assert {:error, {:call_start_failed, :no_engine}} =
               Manager.start_call(request, manager.manager)

      assert_receive {:telemetry, [:fermix, :phone_call, :run_error], _measurements, meta}

      row = row!(ctx, meta.call_id)
      assert row.status == "failed"
      assert row.failure_reason == "worker_start_failed"
      assert is_nil(row.dispatch_claimed_at)
    end
  end

  describe "the end report" do
    test "is written once by the Manager, then reported into the conversation", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_invented_1")

      report = %{
        status: "ended",
        outcome: "confirmed",
        outcome_facts: %{"time" => "19:30"},
        evidence: [%{speaker: "recipient", text: "Two at seven thirty, booked."}],
        voice_seconds: 140,
        usage_state: "voice_duration_confirmed"
      }

      :ok = in_worker(call, &Manager.report_end(&1.manager, &1.call_id, report))
      assert_receive {:telemetry, [:fermix, :phone_call, :run_complete], _measurements, meta}
      assert meta.outcome == "confirmed"

      assert_receive {:dispatched, notice}
      assert notice.content =~ "[phone call #{call.id}] The call ended."
      assert notice.metadata.harness_continuation_depth == 1

      row = row!(ctx, call.id)
      assert row.status == "ended"
      assert row.outcome == "confirmed"
      assert row.provider_session_id == "sess_invented_1"

      :ok =
        in_worker(
          call,
          &Manager.report_end(&1.manager, &1.call_id, %{report | outcome: "unknown"})
        )

      _state = :sys.get_state(manager.pid)
      assert row!(ctx, call.id).outcome == "confirmed"
    end

    test "the outcome's uncertainty note in the report reaches the row and status", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_invented_9")

      # The report as the worker builds it from `Outcome.to_report/1`.
      report =
        Map.merge(
          %{status: "ended", usage_state: "voice_duration_confirmed", voice_seconds: 60},
          %{
            outcome: "options",
            outcome_facts: %{"options" => ["21:00 on Saturday"]},
            evidence: [%{speaker: "recipient", text: "Only nine is open."}],
            uncertainty: "The recipient offered this but did not confirm it was done."
          }
        )

      :ok = in_worker(call, &Manager.report_end(&1.manager, &1.call_id, report))
      assert_receive {:telemetry, [:fermix, :phone_call, :run_complete], _measurements, _meta}

      assert row!(ctx, call.id).outcome_uncertainty ==
               "The recipient offered this but did not confirm it was done."

      assert {:ok, view} = Manager.status(call.id, "default", repo: ctx.repo, now: @t0)
      assert view.outcome_uncertainty =~ "did not confirm it was done"
      assert view.outcome_uncertainty =~ ~s(<untrusted_tool_result source="phone_call_recipient">)
    end

    test "a report the ledger refuses is settled by what the row proves", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = claim!(call)

      :ok =
        in_worker(
          call,
          &Manager.report_end(&1.manager, &1.call_id, %{status: "ended", outcome: "confirmed"})
        )

      assert_receive {:telemetry, [:fermix, :phone_call, :run_error], _measurements, meta}
      assert meta.status == "dispatch_unknown"
      assert row!(ctx, call.id).failure_reason == "invalid_end_report"
    end

    test "a refused report for a call whose closure is recorded settles it ended", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_closed_2")
      {:ok, _row} = closure!(call, DateTime.add(@t0, 95, :second))

      :ok =
        in_worker(
          call,
          &Manager.report_end(&1.manager, &1.call_id, %{status: "ended", outcome: "confirmed"})
        )

      assert_receive {:telemetry, [:fermix, :phone_call, :run_complete], _measurements, meta}
      assert meta.status == "ended"
      _state = :sys.get_state(manager.pid)
      refute_received {:hangup, _session}

      row = row!(ctx, call.id)
      assert row.outcome == "unknown"
      assert row.outcome_uncertainty =~ "could not be stored"
      assert row.failure_reason == "invalid_end_report"
      refute Ledger.holds_slot?(row, @t0)
    end
  end

  describe "a ledger that does not answer" do
    test "a refused terminal write keeps its report and lands later, logged once each way",
         ctx do
      info_logs!()
      store = scripted!(ctx, %{terminalize: [:busy, :busy]})
      manager = start_manager(ctx, repo: store, write_schedule: scheduling(self()))
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_retry_1")

      log =
        capture_log(fn ->
          :ok = in_worker(call, &Manager.report_end(&1.manager, &1.call_id, @confirmed_report))
          assert_receive {:scheduled, {:phone_call_retry_write, id, _op, 2} = retry, 1_000}
          assert id == call.id
          send(manager.pid, retry)
          assert_receive {:scheduled, {:phone_call_retry_write, ^id, _op, 3} = again, 2_000}
          send(manager.pid, again)
          assert_receive {:telemetry, [:fermix, :phone_call, :run_complete], _measurements, _meta}
        end)

      assert log |> String.split("terminal write failed") |> length() == 2
      assert log =~ "terminal write landed on attempt 3"
      assert %{status: "ended", outcome: "confirmed"} = row!(ctx, call.id)
      assert_receive {:dispatched, _notice}
    end

    test "a terminal write still refused at its bound is left for the next boot", ctx do
      store = scripted!(ctx, %{terminalize: List.duplicate(:busy, 5)})
      manager = start_manager(ctx, repo: store, write_schedule: scheduling(self()))
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_retry_2")

      log =
        capture_log(fn ->
          :ok = in_worker(call, &Manager.report_end(&1.manager, &1.call_id, @confirmed_report))

          for attempt <- 2..5 do
            assert_receive {:scheduled, {:phone_call_retry_write, _id, _op, ^attempt} = retry,
                            _wait}

            send(manager.pid, retry)
          end

          _state = :sys.get_state(manager.pid)
        end)

      assert log =~ "terminal write not made after 5 attempts"
      refute_received {:scheduled, _message, _wait}
      refute Ledger.terminal?(row!(ctx, call.id).status)
    end

    test "a terminal write that timed out but landed runs its closer and hand-off once", ctx do
      store = scripted!(ctx, %{terminalize: [:landed]})
      manager = start_manager(ctx, repo: store, write_schedule: scheduling(self()))
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_late_1")

      :ok = in_worker(call, &Manager.report_end(&1.manager, &1.call_id, @confirmed_report))
      assert_receive {:scheduled, {:phone_call_retry_write, _id, _op, 2} = retry, _wait}
      refute_received {:telemetry, [:fermix, :phone_call, :run_complete], _measurements, _meta}
      assert row!(ctx, call.id).status == "ended"

      send(manager.pid, retry)
      assert_receive {:telemetry, [:fermix, :phone_call, :run_complete], _measurements, _meta}
      assert_receive {:dispatched, _notice}
      _state = :sys.get_state(manager.pid)
      refute_received {:telemetry, [:fermix, :phone_call, :run_complete], _measurements, _meta}
      refute_received {:dispatched, _again}
    end

    test "an admission it committed late is refused, and the row fails with nothing dialed",
         ctx do
      store = scripted!(ctx, %{admit: [:landed]})
      manager = start_manager(ctx, repo: store, write_schedule: scheduling(self()))

      assert {:error, :timeout} = Manager.start_call(request(), manager.manager)
      refute_received {:started, _id, _pid, _args}

      assert_receive {:scheduled,
                      {:phone_call_retry_write, id, {:undispatched, "admission_unanswered"}, 1} =
                        follow_up, 0}

      assert %{status: "admitted"} = row!(ctx, id)
      send(manager.pid, follow_up)
      _state = :sys.get_state(manager.pid)

      assert %{status: "failed", dispatch_claimed_at: nil, failure_reason: "admission_unanswered"} =
               row!(ctx, id)

      refute_received {:started, _id, _pid, _args}
    end

    test "an admission the Repo turned away leaves no row to settle", ctx do
      store = scripted!(ctx, %{admit: [:unrun]})
      manager = start_manager(ctx, repo: store, write_schedule: scheduling(self()))

      assert {:error, :timeout} = Manager.start_call(request(), manager.manager)
      assert_receive {:scheduled, {:phone_call_retry_write, id, _op, 1} = follow_up, 0}
      send(manager.pid, follow_up)
      _state = :sys.get_state(manager.pid)

      assert {:error, :not_found} = Ledger.get(id, server: ctx.repo)
      assert {:ok, []} = Ledger.list_recent("default", server: ctx.repo)
      assert Process.alive?(manager.pid)
    end

    test "a cleanup count it does not answer sends no hang-up", ctx do
      store = scripted!(ctx, %{consume: [:unrun]})
      manager = start_manager(ctx, repo: store)
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_count_1")

      assert kill!(call, manager).status == "closure_unconfirmed"
      _state = :sys.get_state(manager.pid)
      refute_received {:hangup, _session}
      assert row!(ctx, call.id).cleanup_attempts == 0
    end
  end

  describe "whether a call holds the slot" do
    test "published at admission and freed by the terminal write", ctx do
      manager = start_manager(ctx)
      _state = :sys.get_state(manager.pid)
      refute Manager.slot_held?(@t0, manager.manager)

      call = start_call!(manager)
      assert Manager.slot_held?(@t0, manager.manager)

      :ok =
        in_worker(
          call,
          &Manager.report_end(&1.manager, &1.call_id, %{status: "failed", outcome: "unknown"})
        )

      assert_receive {:telemetry, [:fermix, :phone_call, :run_error], _measurements, _meta}
      _state = :sys.get_state(manager.pid)
      refute Manager.slot_held?(@t0, manager.manager)
    end

    test "an uncertain call holds it until its slot expires", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = claim!(call)
      assert kill!(call, manager).status == "dispatch_unknown"
      _state = :sys.get_state(manager.pid)

      expires = DateTime.add(@t0, Limits.slot_hold_ms(), :millisecond)
      assert Manager.slot_held?(DateTime.add(expires, -1, :second), manager.manager)
      refute Manager.slot_held?(expires, manager.manager)
    end
  end

  describe "a worker lost without its report" do
    test "before its dispatch claim: failed, nothing dialed, never restarted", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)

      meta = kill!(call, manager)
      assert meta.status == "failed"

      row = row!(ctx, call.id)
      assert row.failure_reason == "worker_lost"
      assert is_nil(row.dispatch_claimed_at)
      assert DynamicSupervisor.which_children(manager.calls) == []
      refute_received {:started, _id, _pid, _args}
      refute_received {:hangup, _session}
    end

    test "after its claim with no session id: dispatch_unknown, the slot still held", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = claim!(call)

      assert kill!(call, manager).status == "dispatch_unknown"
      assert row!(ctx, call.id).outcome == "unknown"
      refute_received {:hangup, _session}

      assert {:error, {:slot_held, holder}} = Manager.start_call(request(), manager.manager)
      assert holder == call.id
    end

    test "with a known session: closure_unconfirmed and one hang-up for that session", ctx do
      test = self()

      manager =
        start_manager(ctx,
          hangup: fn session_id ->
            send(test, {:hangup, session_id})
            {:error, :session_unreachable}
          end
        )

      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_invented_2")
      {:ok, _row} = in_worker(call, &Ledger.advance(&1.call_id, "active", @t0, server: &1.repo))

      assert kill!(call, manager).status == "closure_unconfirmed"
      assert_receive {:hangup, "sess_invented_2"}
      _state = :sys.get_state(manager.pid)
      refute_received {:hangup, _again}

      row = row!(ctx, call.id)
      assert row.cleanup_attempts == 1
      assert row.cleanup_error =~ "session_unreachable"
      assert row.outcome == "unknown"
    end

    test "with a hang-up already counted: closure_unconfirmed and none from the Manager", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_counted_1")

      {:ok, _row} =
        in_worker(call, &Ledger.consume(&1.call_id, :cleanup_attempts, server: &1.repo))

      assert kill!(call, manager).status == "closure_unconfirmed"
      _state = :sys.get_state(manager.pid)
      refute_received {:hangup, _session}
      assert row!(ctx, call.id).cleanup_attempts == 1
    end

    test "after the provider confirmed its end: ended at that closure, no hang-up, slot free",
         ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_closed_1")
      closed_at = DateTime.add(@t0, 95, :second)
      {:ok, _row} = closure!(call, closed_at)

      assert kill!(call, manager).status == "ended"
      _state = :sys.get_state(manager.pid)
      refute_received {:hangup, _session}

      row = row!(ctx, call.id)
      assert row.outcome == "unknown"
      assert row.outcome_uncertainty =~ "never read"
      assert row.voice_seconds == 94
      assert row.ended_at == closed_at
      assert row.failure_reason == "worker_lost"
      refute Ledger.holds_slot?(row, @t0)
      refute Manager.slot_held?(@t0, manager.manager)
    end
  end

  describe "cancel/3" do
    test "an undispatched call ends at once and its later claim fails, so it is never dialed",
         ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)

      assert {:ok, :cancelled} = Manager.cancel(call.id, "default", manager.manager)
      assert_receive {:cancel_asked, id, :owner}
      assert id == call.id

      assert {:error, {:not_admitted, "failed"}} = claim!(call)
      assert row!(ctx, call.id).failure_reason == "cancelled_by_owner"
      assert {:error, :already_terminal} = Manager.cancel(call.id, "default", manager.manager)
    end

    test "a dispatched call is asked to stop and reads stopping until its end is known", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_invented_3")

      assert {:ok, :stopping} = Manager.cancel(call.id, "default", manager.manager)
      assert_receive {:cancel_asked, _id, :owner}

      assert {:ok, %{state: "stopping", dialed: true}} =
               Manager.status(call.id, "default", repo: ctx.repo, now: @t0)
    end

    test "another owner's call is not found", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)

      assert {:error, :not_found} = Manager.cancel(call.id, "someone-else", manager.manager)
      assert {:error, :not_found} = Manager.status(call.id, "someone-else", repo: ctx.repo)
    end
  end

  describe "the off switch" do
    test "ends undispatched work, stops a live call, refuses starts, keeps status", ctx do
      manager = start_manager(ctx)
      first = start_call!(manager)
      {:ok, _row} = session!(first, "sess_invented_4")

      assert %{cancelled: 0, stopping: 1} = Manager.disable(manager.manager)
      assert_receive {:cancel_asked, id, :disabled}
      assert id == first.id

      assert {:error, :disabled} = Manager.start_call(request(), manager.manager)

      assert {:ok, %{state: "stopping"}} =
               Manager.status(first.id, "default", repo: ctx.repo, now: @t0)
    end

    test "an admitted call that has not dispatched ends with nothing dialed", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)

      assert %{cancelled: 1, stopping: 0} = Manager.disable(manager.manager)
      assert {:error, {:not_admitted, "failed"}} = claim!(call)
      assert row!(ctx, call.id).failure_reason == "phone_calls_disabled"
    end

    test "re-enabling releases no uncertain slot and redials nothing", ctx do
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = claim!(call)
      Manager.disable(manager.manager)
      assert kill!(call, manager).status == "dispatch_unknown"

      assert :ok = Manager.enable(manager.manager)
      assert {:error, {:slot_held, holder}} = Manager.start_call(request(), manager.manager)
      assert holder == call.id
      refute_received {:started, _id, _pid, _args}
    end
  end

  describe "boot reconciliation" do
    defp seed!(ctx, request_id, steps) do
      brief = brief!()

      attrs = %{
        request_id: request_id,
        parent_session: request_id,
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
        prompt_version: "phone-test-1",
        carrier_profile: "telnyx_credential_v1"
      }

      {:ok, {:admitted, row}} = Ledger.admit(attrs, @t0, server: ctx.repo)
      Enum.each(steps, & &1.(row.id))
      row.id
    end

    defp end_row!(ctx, id),
      do: {:ok, _row} = Ledger.terminalize(id, "ended", %{ended_at: @t0}, server: ctx.repo)

    test "settles every row no worker owns by what it proves, and redials nothing", ctx do
      claim = fn id -> {:ok, _row} = Ledger.claim_dispatch(id, @t0, server: ctx.repo) end

      session = fn id ->
        {:ok, _row} = Ledger.record_session(id, "sess_boot_1", @t0, server: ctx.repo)
      end

      # One outstanding call at a time: each seeded row but the last ends
      # first, then is re-opened as the case it stands for.
      admitted = seed!(ctx, "main-boot-1", [])
      {:ok, _row} = Ledger.fail_undispatched(admitted, "seed", @t0, server: ctx.repo)
      unknown = seed!(ctx, "main-boot-2", [claim])
      end_row!(ctx, unknown)
      live = seed!(ctx, "main-boot-3", [claim, session])

      TelemetryCapture.attach(@events, parent_session: "main-boot-3")
      manager = start_manager(ctx, reconcile: true)

      assert_receive {:telemetry, [:fermix, :phone_call, :run_error], _measurements, meta}
      assert meta.status == "closure_unconfirmed"
      assert_receive {:hangup, "sess_boot_1"}
      assert row!(ctx, live).failure_reason == "engine_restarted"
      refute_received {:started, _id, _pid, _args}
      assert DynamicSupervisor.which_children(manager.calls) == []
    end

    test "a call whose closure was recorded ends ended at it, unread, with no hang-up", ctx do
      claim = fn id -> {:ok, _row} = Ledger.claim_dispatch(id, @t0, server: ctx.repo) end

      session = fn id ->
        {:ok, _row} = Ledger.record_session(id, "sess_boot_6", @t0, server: ctx.repo)
      end

      closed_at = DateTime.add(@t0, 40, :second)

      closure = fn id ->
        {:ok, _row} =
          Ledger.record_closure(id, %{at: closed_at, reason: nil, voice_seconds: nil},
            server: ctx.repo
          )
      end

      id = seed!(ctx, "main-boot-6", [claim, session, closure])
      TelemetryCapture.attach(@events, parent_session: "main-boot-6")
      _manager = start_manager(ctx, reconcile: true)

      assert_receive {:telemetry, [:fermix, :phone_call, :run_complete], _measurements, meta}
      assert meta.status == "ended"
      refute_received {:hangup, _session}

      row = row!(ctx, id)
      assert row.ended_at == closed_at
      assert row.outcome_uncertainty =~ "never read"
      assert row.failure_reason == "engine_restarted"
    end

    test "an undispatched row ends failed and a claimed one dispatch_unknown", ctx do
      claim = fn id -> {:ok, _row} = Ledger.claim_dispatch(id, @t0, server: ctx.repo) end
      undispatched = seed!(ctx, "main-boot-4", [])
      TelemetryCapture.attach(@events, parent_session: "main-boot-4")
      manager = start_manager(ctx, reconcile: true)
      assert_receive {:telemetry, [:fermix, :phone_call, :run_error], _measurements, _meta}
      assert %{status: "failed", dispatch_claimed_at: nil} = row!(ctx, undispatched)
      :ok = stop_supervised!(Manager)

      claimed = seed!(ctx, "main-boot-5", [claim])
      TelemetryCapture.attach(@events, parent_session: "main-boot-5")

      start_supervised!(
        {Manager,
         name: :"phone_manager_again_#{ctx.unique}",
         call_module: FakeCall,
         hangup: fn _session -> :ok end,
         repo: ctx.repo,
         call_supervisor: manager.calls,
         handoff_supervisor: manager.handoff,
         now_fn: fn -> @t0 end,
         timer_enabled: false}
      )

      assert_receive {:telemetry, [:fermix, :phone_call, :run_error], _measurements, meta}
      assert meta.status == "dispatch_unknown"
      assert row!(ctx, claimed).status == "dispatch_unknown"
      refute_received {:hangup, _session}
    end
  end

  describe "the orderly stop's drain" do
    test "ends undispatched work with nothing dialed and tells the worker it is the engine's stop",
         ctx do
      test = self()

      manager =
        start_manager(ctx,
          drain_schedule: fn message, ms ->
            send(test, {:drain_deadline, message, ms})
            make_ref()
          end
        )

      call = start_call!(manager)
      drainer = Task.async(fn -> Manager.drain(manager.manager) end)

      assert_receive {:cancel_asked, id, :shutdown}
      assert id == call.id
      assert_receive {:telemetry, [:fermix, :phone_call, :run_error], _measurements, meta}
      assert meta.status == "failed"

      row = row!(ctx, call.id)
      assert row.failure_reason == "engine_stopped"
      assert is_nil(row.dispatch_claimed_at)
      assert {:error, {:not_admitted, "failed"}} = claim!(call)

      capture_log(fn ->
        GenServer.stop(call.pid, :normal)
        assert :drained = Task.await(drainer)
      end)

      assert {:error, :engine_stopping} = Manager.start_call(request(), manager.manager)
    end
  end

  describe "a store that is off or failing" do
    test "with durable memory off the boot neither scans nor prunes, and says so once", ctx do
      info_logs!()
      repo = :"phone_manager_off_repo_#{ctx.unique}"

      start_supervised!(
        {Repo, name: repo, enabled: false, database_path: ":memory:"},
        id: repo
      )

      log =
        capture_log(fn ->
          manager = start_manager(ctx, repo: repo, reconcile: true)
          _state = :sys.get_state(manager.pid)
        end)

      assert log =~ "durable memory is off"
      refute log =~ "scan failed"
      refute log =~ "prune failed"
    end

    test "a failing prune is logged once when it starts and once when it ends", ctx do
      info_logs!()
      {:ok, store} = BusyStore.start_link(%{prune: true})
      on_exit(fn -> Process.alive?(store) && GenServer.stop(store) end)

      log =
        capture_log(fn ->
          manager = start_manager(ctx, repo: store, reconcile: true)

          for _day <- 1..3 do
            send(manager.pid, :phone_call_prune)
            _state = :sys.get_state(manager.pid)
          end

          :ok = BusyStore.heal(store)
          send(manager.pid, :phone_call_prune)
          _state = :sys.get_state(manager.pid)
          send(manager.pid, :phone_call_prune)
          _state = :sys.get_state(manager.pid)
        end)

      assert log |> String.split("retention prune failed") |> length() == 2
      assert log |> String.split("retention prune works again") |> length() == 2
      assert log =~ "after 4 failed"
    end
  end
end
