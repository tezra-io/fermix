defmodule FermixCore.Harness.ManagerTest do
  # async: false — each test spawns real OS process groups through a per-test
  # CommandHost supervisor + a per-test RunSupervisor, drives a per-test Repo, and
  # establishes the `[fermix_core.harness]` app-env baseline here (never leaked).
  # All artifacts land under SafeRm tmp dirs; the vendor CLI is a generated stub.
  use ExUnit.Case, async: false

  alias FermixCore.Harness.Adapters.ClaudeHeadless
  alias FermixCore.Harness.Adapters.CodexExec
  alias FermixCore.Harness.Continuation
  alias FermixCore.Harness.DeliveryWorker
  alias FermixCore.Harness.Ledger
  alias FermixCore.Harness.Manager
  alias FermixCore.Harness.RunSupervisor
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.FakeVendorCli

  @fixtures Path.expand("../../fixtures/harness", __DIR__)
  @codex_session "019f7d3f-3f21-7482-8c91-749fb4713417"
  @poll_max 200
  @poll_ms 20

  # Delivery seam: a channel adapter that records every send to the sink pid the
  # test stashes in app-env (safe under `async: false` — no test runs concurrently
  # with this module). `send_message/3` runs inside `ChannelSend`'s spawned
  # watchdog, so it reads the sink from the shared app-env.
  defmodule RecordingAdapter do
    def send_message(destination, text, _opts) do
      case Application.get_env(:fermix_core, :harness_test_sink) do
        pid when is_pid(pid) -> send(pid, {:delivered, destination, text})
        _absent -> :ok
      end

      :ok
    end
  end

  # Continuation seam (design §23.2): the channels-side re-ingest is injected by
  # module, so the manager tests record the notice instead of touching a gateway.
  # `reply` lets a test drive the dispatch-failure branch.
  defmodule RecordingDispatcher do
    def dispatch(notice) do
      case Application.get_env(:fermix_core, :harness_test_sink) do
        pid when is_pid(pid) -> send(pid, {:continued, notice})
        _absent -> :ok
      end

      Application.get_env(:fermix_core, :harness_test_continuation_reply, :ok)
    end
  end

  setup do
    prior = Application.get_env(:fermix_core, :harness)
    Application.put_env(:fermix_core, :harness, max_active: 2)
    Application.put_env(:fermix_core, :harness_test_sink, self())

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-harness-manager-#{unique}.db")
    repo = :"harness_manager_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    run_sup = start_run_supervisor()
    host_sup = start_host_supervisor()
    workspace = FermixTestSupport.SafeRm.make_tmp_dir!("harness-manager-workspace")
    stub_dir = FermixTestSupport.SafeRm.make_tmp_dir!("harness-manager-stub")
    artifacts_base = FermixTestSupport.SafeRm.make_tmp_dir!("harness-manager-artifacts")
    home = FermixTestSupport.SafeRm.make_tmp_dir!("harness-manager-home")
    runs_root = Path.join(artifacts_base, "harness/runs")
    File.mkdir_p!(runs_root)

    on_exit(fn ->
      restore(:harness, prior)
      Application.delete_env(:fermix_core, :harness_test_sink)
      Application.delete_env(:fermix_core, :harness_test_continuation_reply)
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      Enum.each([workspace, stub_dir, artifacts_base, home], &FermixTestSupport.SafeRm.rm_rf!/1)
    end)

    %{
      repo: repo,
      run_sup: run_sup,
      host_sup: host_sup,
      workspace: workspace,
      stub_dir: stub_dir,
      runs_root: runs_root,
      home: home
    }
  end

  # --- Normal completion --------------------------------------------------

  describe "normal completion flow" do
    test "admits, runs the stub CLI to completion, terminalizes + delivers", ctx do
      manager = start_manager(ctx)
      stub = completing_stub(ctx)

      assert {:ok, run_id} = Manager.start_run(chat_request(ctx, stub), manager)

      assert row = await_status(ctx.repo, run_id, "completed")
      assert row.vendor_session_id == @codex_session
      assert Map.has_key?(row.usage, "input_tokens")
      assert row.exit_code == 0

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "[run #{run_id}]"
      assert text =~ "codex-final"

      assert delivered_row = await_delivery(ctx.repo, run_id)
      assert delivered_row.delivery_status == "delivered"
    end

    test "a claude run delivers the stream-harvested result body (result.txt persisted)", ctx do
      manager = start_manager(ctx)

      stub =
        FakeVendorCli.write!(ctx.stub_dir, lines: fixture_lines("claude_stream_success.jsonl"))

      request =
        ctx
        |> chat_request(stub)
        |> Map.put(:vendor, "claude")
        |> Map.put(:adapter, ClaudeHeadless)

      assert {:ok, run_id} = Manager.start_run(request, manager)
      assert await_status(ctx.repo, run_id, "completed")

      # Claude's result rides the stream (no vendor `-o`); the delivery must still
      # carry the body, which means the Run persisted it to result.txt.
      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "[run #{run_id}]"
      assert text =~ "ok"
      assert File.read!(Path.join([ctx.runs_root, run_id, "result.txt"])) == "ok"
    end
  end

  # --- Admission refusals + blocked-row split (spec §5 / D8) --------------

  describe "admission refusals" do
    test "param error returns the error with NO ledger row", ctx do
      manager = start_manager(ctx)
      stub = completing_stub(ctx)
      request = ctx |> chat_request(stub) |> Map.put(:params, %{bogus: 1})

      assert {:error, {:unknown_param, :bogus}} = Manager.start_run(request, manager)
      assert {:ok, []} = Ledger.list(%{}, server: ctx.repo)
    end

    test "cli_unavailable (attended chat) returns the error with NO ledger row", ctx do
      manager = start_manager(ctx)
      request = ctx |> chat_request(missing_cli()) |> Map.put(:ctx, missing_cli_ctx(ctx))

      assert {:error, :cli_unavailable} = Manager.start_run(request, manager)
      assert {:ok, []} = Ledger.list(%{}, server: ctx.repo)
    end

    test "cli_unavailable (scheduled) ledgers a blocked row and delivers it", ctx do
      manager = start_manager(ctx)

      request =
        ctx
        |> scheduled_request(missing_cli())
        |> Map.put(:ctx, missing_cli_ctx(ctx))

      assert {:error, :cli_unavailable} = Manager.start_run(request, manager)

      assert [row] = list_runs(ctx.repo)
      assert row.status == "blocked"
      assert row.reason == "cli_unavailable"

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "cli_unavailable"
      assert await_delivery(ctx.repo, row.id).delivery_status == "delivered"
    end

    test "artifact_quota (attended chat) returns the error with NO ledger row", ctx do
      manager = start_manager(ctx, artifacts_opts: quota_zero_opts(ctx))

      assert {:error, {:artifact_quota, _detail}} =
               Manager.start_run(chat_request(ctx, completing_stub(ctx)), manager)

      assert {:ok, []} = Ledger.list(%{}, server: ctx.repo)
    end

    test "artifact_quota (scheduled) ledgers a blocked row and delivers it", ctx do
      manager = start_manager(ctx, artifacts_opts: quota_zero_opts(ctx))

      assert {:error, {:artifact_quota, _detail}} =
               Manager.start_run(scheduled_request(ctx, completing_stub(ctx)), manager)

      assert [row] = list_runs(ctx.repo)
      assert row.status == "blocked"
      assert row.reason == "artifact_quota"
      assert_receive {:delivered, "123", _text}, 5_000
    end

    test "workspace_denied (scheduled) ledgers a blocked row and delivers it", ctx do
      manager = start_manager(ctx)

      block = %{
        vendor: "codex",
        cwd: "/repo/not-granted",
        snapshot: scheduled_snapshot(),
        origin_session_id: "cron_job_x_20260720",
        reason: :workspace_denied
      }

      assert :ok = Manager.block_scheduled(block, manager)

      assert [row] = list_runs(ctx.repo)
      assert row.status == "blocked"
      assert row.reason == "workspace_denied"

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "workspace_denied"
      assert await_delivery(ctx.repo, row.id).delivery_status == "delivered"
    end

    test "consent_required (scheduled) ledgers a blocked row and delivers guidance", ctx do
      manager = start_manager(ctx)

      block = %{
        vendor: "codex",
        cwd: "/repo/needs-consent",
        snapshot: scheduled_snapshot(),
        origin_session_id: "cron_job_x_20260721",
        reason: :consent_required
      }

      assert :ok = Manager.block_scheduled(block, manager)

      assert [row] = list_runs(ctx.repo)
      assert row.status == "blocked"
      assert row.reason == "consent_required"

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "consent_required"
      # The delivered guidance tells the owner how to approve coding agents.
      assert text =~ "approved"
      assert await_delivery(ctx.repo, row.id).delivery_status == "delivered"
    end

    test "max_active refuses a third run with no new row", ctx do
      manager = start_manager(ctx)
      hang = hanging_stub(ctx)

      assert {:ok, _a} = Manager.start_run(chat_request(ctx, hang), manager)

      assert {:ok, _b} =
               Manager.start_run(
                 chat_request(ctx, hang, cwd: sibling_workspace(ctx, "b")),
                 manager
               )

      third = chat_request(ctx, hang, cwd: sibling_workspace(ctx, "c"))
      assert {:error, :max_active} = Manager.start_run(third, manager)
    end

    test "workspace_locked refuses a second run contending on the same worktree", ctx do
      manager = start_manager(ctx)
      hang = hanging_stub(ctx)

      assert {:ok, _a} = Manager.start_run(chat_request(ctx, hang), manager)

      assert {:error, {:workspace_locked, root}} =
               Manager.start_run(chat_request(ctx, hang), manager)

      assert is_binary(root)
    end
  end

  # --- Live status transition ---------------------------------------------

  describe "starting → running" do
    test "a live run reports 'running' once its first event streams", ctx do
      manager = start_manager(ctx)

      # Emits one event (flips starting → running) then hangs before the next.
      stub =
        FakeVendorCli.write!(ctx.stub_dir,
          lines: [
            ~s({"type":"thread.started","thread_id":"#{@codex_session}"}),
            ~s({"type":"turn.started"})
          ],
          hang_after: 1
        )

      assert {:ok, run_id} = Manager.start_run(chat_request(ctx, stub), manager)

      assert row = await_status(ctx.repo, run_id, "running")
      assert row.status == "running"

      assert :ok = Manager.cancel(run_id, :owner, manager)
      assert await_status(ctx.repo, run_id, "cancelled")
    end
  end

  # --- Run crash while the daemon stays up --------------------------------

  describe "run crash (daemon up)" do
    test "an abnormal Harness.Run DOWN → failed/:run_crashed + delivery", ctx do
      manager = start_manager(ctx)

      assert {:ok, run_id} = Manager.start_run(chat_request(ctx, hanging_stub(ctx)), manager)
      assert await_active(ctx.repo, run_id)

      pid = run_child_pid(ctx.run_sup)
      Process.exit(pid, :kill)

      assert row = await_status(ctx.repo, run_id, "failed")
      assert row.reason == "run_crashed"
      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "run_crashed"
    end
  end

  # --- Background-only delivery -------------------------------------------

  describe "background runs" do
    test "a launched run delivers its outcome to the channel with no caller waiting", ctx do
      manager = start_manager(ctx)
      {:ok, run_id} = Manager.start_run(chat_request(ctx, completing_stub(ctx)), manager)

      assert await_status(ctx.repo, run_id, "completed")
      assert_receive {:delivered, "123", _text}, 5_000
    end
  end

  # --- Completion continuation (design §23.2) ------------------------------

  describe "completion continuation" do
    test "a chat-origin completion dispatches exactly one continuation and marks it delivered",
         ctx do
      manager = start_manager(ctx, continuation_dispatcher: RecordingDispatcher)
      {:ok, run_id} = Manager.start_run(chat_request(ctx, completing_stub(ctx)), manager)

      assert await_status(ctx.repo, run_id, "completed")

      assert_receive {:continued, notice}, 5_000
      assert notice.platform == "telegram"
      assert notice.destination == "123"
      assert notice.content =~ "[coding run #{run_id} finished]"
      assert notice.content =~ "codex · completed"
      assert notice.content =~ "codex-final"
      assert notice.content =~ "Continue the request this run was for"
      assert notice.metadata.harness_continuation == true
      assert notice.metadata.harness_run_id == run_id
      assert notice.metadata.harness_continuation_depth == 1

      # The agent's turn IS the notification: no text push, and the row is marked
      # delivered so the DeliveryWorker never double-notifies.
      refute_receive {:delivered, _destination, _text}, 200
      assert await_delivery(ctx.repo, run_id).delivery_status == "delivered"

      worker = start_delivery_worker(ctx)
      _ = tick_worker(worker)
      refute_receive {:delivered, _destination, _text}, 200
      refute_receive {:continued, _notice}, 200
    end

    test "a failed run's continuation carries the reason and diagnostics", ctx do
      manager = start_manager(ctx, continuation_dispatcher: RecordingDispatcher)

      {:ok, run_id} = Manager.start_run(chat_request(ctx, hanging_stub(ctx)), manager)
      assert await_active(ctx.repo, run_id)

      pid = run_child_pid(ctx.run_sup)
      Process.exit(pid, :kill)

      assert await_status(ctx.repo, run_id, "failed")
      assert_receive {:continued, notice}, 5_000
      assert notice.content =~ "reason: run_crashed"
    end

    test "a failed dispatch leaves delivery pending so the worker delivers the text", ctx do
      Application.put_env(:fermix_core, :harness_test_continuation_reply, {:error, :boom})
      manager = start_manager(ctx, continuation_dispatcher: RecordingDispatcher)

      {:ok, run_id} = Manager.start_run(chat_request(ctx, completing_stub(ctx)), manager)
      assert await_status(ctx.repo, run_id, "completed")
      assert_receive {:continued, _notice}, 5_000

      refute_receive {:delivered, _destination, _text}, 200
      assert {:ok, row} = Ledger.get(run_id, server: ctx.repo)
      assert row.delivery_status == "pending"

      worker = start_delivery_worker(ctx)
      _ = tick_worker(worker)
      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "[run #{run_id}]"
      assert await_delivery(ctx.repo, run_id).delivery_status == "delivered"
    end

    test "a scheduled origin never continues — plain durable delivery", ctx do
      manager = start_manager(ctx, continuation_dispatcher: RecordingDispatcher)
      {:ok, run_id} = Manager.start_run(scheduled_request(ctx, completing_stub(ctx)), manager)

      assert await_status(ctx.repo, run_id, "completed")
      assert_receive {:delivered, "123", _text}, 5_000
      refute_receive {:continued, _notice}, 200
      assert await_delivery(ctx.repo, run_id).delivery_status == "delivered"
    end

    test "a launched run inherits the launching turn's depth + 1 on its row", ctx do
      manager = start_manager(ctx, continuation_dispatcher: RecordingDispatcher)
      request = ctx |> chat_request(completing_stub(ctx)) |> Map.put(:continuation_depth, 1)

      {:ok, run_id} = Manager.start_run(request, manager)
      assert row = await_status(ctx.repo, run_id, "completed")
      assert row.continuation_depth == 1

      assert_receive {:continued, notice}, 5_000
      assert notice.metadata.harness_continuation_depth == 2
    end

    # The kill switch must not be undone: an owner cancel (`/stop`,
    # `cancel_coding_run`) is not a result, so it takes plain durable delivery and
    # the agent is never handed "continue the request this run was for".
    test "an owner-cancelled chat run never continues — plain durable delivery", ctx do
      manager = start_manager(ctx, continuation_dispatcher: RecordingDispatcher)
      {:ok, run_id} = Manager.start_run(chat_request(ctx, hanging_stub(ctx)), manager)
      assert await_active(ctx.repo, run_id)

      assert :ok = Manager.cancel(run_id, :owner, manager)
      assert await_status(ctx.repo, run_id, "cancelled")

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "cancelled"
      refute_receive {:continued, _notice}, 200
      assert await_delivery(ctx.repo, run_id).delivery_status == "delivered"
    end

    test "at the depth cap nothing continues and the delivered text says so", ctx do
      manager = start_manager(ctx, continuation_dispatcher: RecordingDispatcher)

      request =
        ctx
        |> chat_request(completing_stub(ctx))
        |> Map.put(:continuation_depth, Continuation.max_depth())

      {:ok, run_id} = Manager.start_run(request, manager)
      assert await_status(ctx.repo, run_id, "completed")

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "Automatic follow-up stopped here"
      refute_receive {:continued, _notice}, 200
      assert await_delivery(ctx.repo, run_id).delivery_status == "delivered"
    end
  end

  # --- cancel + stop_all --------------------------------------------------

  describe "cancel" do
    test "cancels an active run (owner intent → cancelled)", ctx do
      manager = start_manager(ctx)
      {:ok, run_id} = Manager.start_run(chat_request(ctx, hanging_stub(ctx)), manager)
      assert await_active(ctx.repo, run_id)

      assert :ok = Manager.cancel(run_id, :owner, manager)
      assert row = await_status(ctx.repo, run_id, "cancelled")
      assert row.reason == nil
    end

    test "unknown id → not_found; already-terminal → already_terminal", ctx do
      manager = start_manager(ctx)
      assert {:error, :not_found} = Manager.cancel("hr_deadbeef0000", :owner, manager)

      {:ok, run_id} = Manager.start_run(chat_request(ctx, completing_stub(ctx)), manager)
      assert await_status(ctx.repo, run_id, "completed")
      assert {:error, :already_terminal} = Manager.cancel(run_id, :owner, manager)
    end
  end

  describe "stop_all" do
    test "cancels every active run and returns the count", ctx do
      manager = start_manager(ctx)
      hang = hanging_stub(ctx)

      {:ok, a} = Manager.start_run(chat_request(ctx, hang), manager)

      {:ok, b} =
        Manager.start_run(chat_request(ctx, hang, cwd: sibling_workspace(ctx, "b")), manager)

      assert await_active(ctx.repo, a)
      assert await_active(ctx.repo, b)

      assert %{cancelled: 2} = Manager.stop_all(manager)
      assert await_status(ctx.repo, a, "cancelled")
      assert await_status(ctx.repo, b, "cancelled")
    end
  end

  # --- Boot reconciliation ------------------------------------------------

  describe "boot reconciliation" do
    test "finalizes interrupted with resume guidance and delivers", ctx do
      run_id = seed_active_run(ctx.repo, ctx.workspace)

      manager = start_manager(ctx, timer_enabled: true)
      _ = :sys.get_state(manager)

      assert row = await_status(ctx.repo, run_id, "interrupted")
      assert row.status == "interrupted"

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "interrupted"
      assert text =~ "Resume:"
      assert text =~ @codex_session
    end

    test "a submitting cloud row without a task id → blocked/:submission_outcome_unknown", ctx do
      cloud_id = seed_submitting_cloud_run(ctx)

      manager = start_manager(ctx, timer_enabled: true)
      _ = :sys.get_state(manager)

      assert row = await_status(ctx.repo, cloud_id, "blocked")
      assert row.reason == "submission_outcome_unknown"

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "submission_outcome_unknown"
      assert text =~ "codex cloud list"
      # Recovery delivery content: the env id (from the `cloud:<env_id>` marker),
      # the created timestamp, and — with no prompt.md — the honest fallback.
      assert text =~ "env: proj-web"
      assert text =~ "created: #{DateTime.to_iso8601(row.created_at)}"
      assert text =~ "(query snapshot unavailable)"
    end

    test "the submission-unknown recovery surfaces the snapshotted query when present", ctx do
      cloud_id = seed_submitting_cloud_run(ctx, query: "reticulate the splines")

      manager = start_manager(ctx, timer_enabled: true)
      _ = :sys.get_state(manager)

      assert await_status(ctx.repo, cloud_id, "blocked")

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "env: proj-web"
      assert text =~ "query: reticulate the splines"
    end
  end

  # --- Idempotence --------------------------------------------------------

  describe "double terminal-signal idempotence" do
    test "a duplicate report + the run's normal DOWN do not re-process the terminal", ctx do
      manager = start_manager(ctx)
      {:ok, run_id} = Manager.start_run(chat_request(ctx, completing_stub(ctx)), manager)

      assert await_status(ctx.repo, run_id, "completed")
      assert_receive {:delivered, "123", _text}, 5_000
      assert await_delivery(ctx.repo, run_id).delivery_status == "delivered"

      # A duplicate terminal report for an already-finalized run is ignored,
      # and the completed run's real DOWN(:normal) is dropped — no second
      # terminalization, no second delivery.
      send(manager, {:harness_report_terminal, run_id, "failed", duplicate_fields()})
      _ = :sys.get_state(manager)

      refute_receive {:delivered, _destination, _text}, 200
      assert {:ok, row} = Ledger.get(run_id, server: ctx.repo)
      assert row.status == "completed"
    end
  end

  # --- Manager construction ----------------------------------------------

  defp start_manager(ctx, overrides \\ []) do
    name = :"harness_manager_#{System.unique_integer([:positive])}"

    opts =
      [
        name: name,
        repo: ctx.repo,
        run_supervisor: ctx.run_sup,
        command_supervisor: ctx.host_sup,
        artifacts_opts: default_artifacts_opts(ctx),
        delivery_opts: [adapter: RecordingAdapter],
        timer_enabled: false
      ]
      |> Keyword.merge(overrides)

    start_supervised!(%{id: name, start: {Manager, :start_link, [opts]}})
    name
  end

  defp default_artifacts_opts(ctx), do: [runs_root: ctx.runs_root, quota_gb: 1000, min_free_gb: 0]
  defp quota_zero_opts(ctx), do: [runs_root: ctx.runs_root, quota_gb: 0, min_free_gb: 0]

  # A per-test DeliveryWorker sharing the manager's repo + recording adapter, with
  # its timer disabled so ticks are driven explicitly (no fixed-sleep coordination).
  defp start_delivery_worker(ctx) do
    name = :"harness_delivery_worker_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      repo: ctx.repo,
      timer_enabled: false,
      delivery_opts: [adapter: RecordingAdapter]
    ]

    start_supervised!(%{id: name, start: {DeliveryWorker, :start_link, [opts]}})
    name
  end

  # `send/2` then a `:sys.get_state/1` barrier: FIFO processing means the read
  # blocks until the drained tick has fully run (no sleeps).
  defp tick_worker(worker) do
    send(worker, :tick)
    :sys.get_state(worker)
    :ok
  end

  # --- Requests -----------------------------------------------------------

  # `overrides` carries only `:cwd` today (sibling workspaces for the
  # capacity/lock tests); other request fields are set by the caller via
  # `Map.put` after building the base request.
  defp chat_request(ctx, stub, overrides \\ []) do
    cwd = Keyword.get(overrides, :cwd, ctx.workspace)

    %{
      vendor: "codex",
      adapter: CodexExec,
      prompt: "do the work",
      cwd: cwd,
      ctx: plan_ctx(cwd, stub),
      params: %{},
      snapshot: chat_snapshot(),
      origin_session_id: "telegram:123:root",
      timeout_minutes: 5,
      progress: :quiet
    }
  end

  defp scheduled_request(ctx, stub, overrides \\ []) do
    ctx
    |> chat_request(stub, overrides)
    |> Map.put(:snapshot, scheduled_snapshot())
    |> Map.put(:origin_session_id, "cron_job_x_20260720")
  end

  defp chat_snapshot do
    %{
      origin_kind: "chat",
      delivery_mode: "channel",
      platform: "telegram",
      destination: "123",
      thread: nil,
      send_opts: nil,
      parent_job_id: nil
    }
  end

  defp scheduled_snapshot do
    %{chat_snapshot() | origin_kind: "scheduled", parent_job_id: "job_x"}
  end

  defp plan_ctx(cwd, stub) do
    %{
      cwd: cwd,
      sandbox_config: %{mode: :strict, workspace_root: cwd, allowed_roots: []},
      find_executable: fn _name -> stub end
    }
  end

  defp missing_cli_ctx(ctx) do
    plan_ctx(ctx.workspace, nil) |> Map.put(:find_executable, fn _name -> nil end)
  end

  # --- Stubs --------------------------------------------------------------

  defp completing_stub(ctx) do
    FakeVendorCli.write!(ctx.stub_dir,
      lines: fixture_lines("codex_exec_success.jsonl"),
      result_text: "codex-final"
    )
  end

  defp hanging_stub(ctx) do
    FakeVendorCli.write!(ctx.stub_dir,
      lines: [~s({"type":"thread.started","thread_id":"t1"})],
      hang_after: 0
    )
  end

  defp missing_cli, do: "does-not-matter"

  defp sibling_workspace(ctx, suffix) do
    dir = Path.join(Path.dirname(ctx.workspace), Path.basename(ctx.workspace) <> "-#{suffix}")
    File.mkdir_p!(dir)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    dir
  end

  defp fixture_lines(name) do
    @fixtures |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
  end

  defp duplicate_fields do
    %{
      reason: "protocol",
      exit_code: nil,
      usage: nil,
      result_text: nil,
      diagnostics_tail: [],
      framing_errors: 0,
      vendor_session_id: nil,
      artifact_truncated: false
    }
  end

  # --- Seeds (reconciliation) ---------------------------------------------

  defp seed_active_run(repo, cwd) do
    id = Ledger.generate_id()

    {:ok, _row} =
      Ledger.admit(
        %{
          id: id,
          vendor: "codex",
          rail: "local",
          status: "starting",
          cwd: cwd,
          worktree_root: cwd,
          lock_roots: ["#{cwd}-#{System.unique_integer([:positive])}"],
          artifacts_dir: Path.join(cwd, "artifacts"),
          resumable: true,
          vendor_session_id: @codex_session,
          origin_kind: "chat",
          origin_session_id: "telegram:123:root",
          delivery_mode: "channel",
          platform: "telegram",
          destination: "123"
        },
        server: repo
      )

    id
  end

  # A cloud `submitting` row uses the `cloud:<env_id>` cwd marker and a real
  # artifacts dir; passing `query:` snapshots a prompt.md so the recovery delivery
  # can surface it (its absence is the honest "(query snapshot unavailable)").
  defp seed_submitting_cloud_run(ctx, opts \\ []) do
    id = Ledger.generate_id()
    artifacts_dir = Path.join(ctx.runs_root, id)
    File.mkdir_p!(artifacts_dir)

    case Keyword.get(opts, :query) do
      nil -> :ok
      query -> File.write!(Path.join(artifacts_dir, "prompt.md"), query)
    end

    {:ok, _row} =
      Ledger.admit(
        %{
          id: id,
          vendor: "codex_cloud",
          rail: "cloud",
          status: "submitting",
          cwd: "cloud:proj-web",
          worktree_root: "cloud:proj-web",
          lock_roots: [],
          artifacts_dir: artifacts_dir,
          origin_kind: "chat",
          origin_session_id: "telegram:123:root",
          delivery_mode: "channel",
          platform: "telegram",
          destination: "123"
        },
        server: ctx.repo
      )

    id
  end

  # --- Bounded polling (never a fixed coordination sleep) -----------------

  defp await_status(repo, run_id, status) do
    poll(fn ->
      case Ledger.get(run_id, server: repo) do
        {:ok, %{status: ^status} = row} -> {:halt, row}
        _other -> :cont
      end
    end) || flunk("run #{run_id} did not reach status #{status}")
  end

  defp await_active(repo, run_id) do
    poll(fn ->
      case Ledger.get(run_id, server: repo) do
        {:ok, %{status: s} = row} when s in ["starting", "running"] -> {:halt, row}
        _other -> :cont
      end
    end) || flunk("run #{run_id} never became active")
  end

  defp await_delivery(repo, run_id) do
    poll(fn ->
      case Ledger.get(run_id, server: repo) do
        {:ok, %{delivery_status: "delivered"} = row} -> {:halt, row}
        _other -> :cont
      end
    end) || flunk("run #{run_id} was never marked delivered")
  end

  defp run_child_pid(run_sup) do
    poll(fn ->
      case DynamicSupervisor.which_children(run_sup) do
        [{_id, pid, _type, _mods} | _rest] when is_pid(pid) -> {:halt, pid}
        _none -> :cont
      end
    end) || flunk("no run child started under the supervisor")
  end

  defp poll(fun) do
    Enum.reduce_while(1..@poll_max, nil, fn _attempt, _acc ->
      case fun.() do
        {:halt, value} -> {:halt, value}
        :cont -> Process.sleep(@poll_ms) && {:cont, nil}
      end
    end)
  end

  defp list_runs(repo) do
    {:ok, rows} = Ledger.list(%{}, server: repo)
    rows
  end

  # --- Supervisors --------------------------------------------------------

  defp start_run_supervisor do
    name = :"harness_run_sup_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {RunSupervisor, :start_link, [[name: name]]}})
    name
  end

  defp start_host_supervisor do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    on_exit(fn ->
      try do
        DynamicSupervisor.stop(sup)
      catch
        :exit, reason when reason in [:noproc, :normal, :shutdown] -> :ok
        :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> :ok
      end
    end)

    sup
  end

  defp restore(:harness, nil), do: Application.delete_env(:fermix_core, :harness)
  defp restore(:harness, value), do: Application.put_env(:fermix_core, :harness, value)
end
