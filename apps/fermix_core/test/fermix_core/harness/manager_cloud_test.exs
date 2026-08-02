defmodule FermixCore.Harness.ManagerCloudTest do
  # async: false — each test drives a per-test Repo + per-test CommandHost
  # supervisor, spawns real OS process groups through the generated cloud stub CLI,
  # and establishes the `[fermix_core.harness]` app-env baseline here. Poll cadence
  # is injected ms-scale so full poll cycles run with no wall-clock coordination.
  use ExUnit.Case, async: false

  alias FermixCore.Harness.Ledger
  alias FermixCore.Harness.Manager
  alias FermixCore.Harness.RunSupervisor
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.FakeCloudCli

  @task_url "https://chatgpt.com/codex/tasks/task_i_abc123"
  @task_id "task_i_abc123"
  @poll_max 200
  @poll_ms 20

  # Delivery seam recorder (app-env sink, safe under async: false).
  defmodule RecordingAdapter do
    def send_message(destination, text, _opts) do
      case Application.get_env(:fermix_core, :harness_cloud_sink) do
        pid when is_pid(pid) -> send(pid, {:delivered, destination, text})
        _absent -> :ok
      end

      :ok
    end
  end

  setup do
    prior = Application.get_env(:fermix_core, :harness)
    Application.put_env(:fermix_core, :harness, max_active: 2)
    Application.put_env(:fermix_core, :harness_cloud_sink, self())

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-harness-cloud-#{unique}.db")
    repo = :"harness_cloud_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    run_sup = start_run_supervisor()
    host_sup = start_host_supervisor()
    stub_dir = FermixTestSupport.SafeRm.make_tmp_dir!("harness-cloud-stub")
    artifacts_base = FermixTestSupport.SafeRm.make_tmp_dir!("harness-cloud-artifacts")
    runs_root = Path.join(artifacts_base, "harness/runs")
    File.mkdir_p!(runs_root)

    on_exit(fn ->
      restore(prior)
      Application.delete_env(:fermix_core, :harness_cloud_sink)
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      Enum.each([stub_dir, artifacts_base], &FermixTestSupport.SafeRm.rm_rf!/1)
    end)

    %{repo: repo, run_sup: run_sup, host_sup: host_sup, stub_dir: stub_dir, runs_root: runs_root}
  end

  # --- Submit ---------------------------------------------------------------

  describe "submit" do
    test "success admits submitting then promotes to polling with persisted fields", ctx do
      # A long poll interval keeps the first tick from firing during the assert, so
      # the freshly-polling row is observed intact.
      manager = start_manager(ctx, cloud_poll_ms: 10_000)
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:pending)])

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      assert {:ok, row} = Ledger.get(run_id, server: ctx.repo)
      assert row.status == "polling"
      assert row.vendor == "codex_cloud"
      assert row.rail == "cloud"
      assert row.cwd == "cloud:proj-web"
      assert row.resumable == false
      assert row.lock_roots == []
      assert row.task_id == @task_id
      assert row.task_url == @task_url
      assert %DateTime{} = row.next_poll_at
      assert %DateTime{} = row.poll_deadline

      assert :ok = Manager.stop_tracking(run_id, manager) |> ok()
    end

    test "an Error line terminalizes blocked/:submit_failed and delivers", ctx do
      manager = start_manager(ctx)

      stub =
        cloud_stub(ctx,
          submit_output: "Error: environment 'proj-web' not found\n",
          submit_exit: 1
        )

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      assert row = await_status(ctx.repo, run_id, "blocked")
      assert row.reason == "submit_failed"
      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "submit_failed"
    end

    test "the not-signed-in diagnostic terminalizes blocked/:cloud_auth", ctx do
      manager = start_manager(ctx)
      stub = cloud_stub(ctx, submit_output: not_signed_in(), submit_exit: 1)

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      assert row = await_status(ctx.repo, run_id, "blocked")
      assert row.reason == "cloud_auth"
    end

    test "a submit timeout terminalizes blocked/:submit_failed", ctx do
      manager = start_manager(ctx, cloud_submit_timeout_ms: 200)
      stub = cloud_stub(ctx, submit_hang: true)

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      assert row = await_status(ctx.repo, run_id, "blocked")
      assert row.reason == "submit_failed"
    end

    test "a query error is refused with NO ledger row (tool boundary)", ctx do
      manager = start_manager(ctx)
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:ready)])

      request = cloud_request(stub, %{query: String.duplicate("x", 200 * 1024 + 1)})
      assert {:error, :query_too_large} = Manager.start_cloud_run(request, manager)
      assert {:ok, []} = Ledger.list(%{}, server: ctx.repo)
    end

    test "a missing binary (attended chat) refuses with NO row", ctx do
      manager = start_manager(ctx)

      request = %{cloud_request(nil) | ctx: %{find_executable: fn _ -> nil end}}
      assert {:error, :cli_unavailable} = Manager.start_cloud_run(request, manager)
      assert {:ok, []} = Ledger.list(%{}, server: ctx.repo)
    end

    test "a missing binary (scheduled) ledgers a blocked row and delivers", ctx do
      manager = start_manager(ctx)

      request =
        cloud_request(nil)
        |> Map.put(:ctx, %{find_executable: fn _ -> nil end})
        |> Map.put(:snapshot, scheduled_snapshot())
        |> Map.put(:origin_session_id, "cron_job_x")

      assert {:error, :cli_unavailable} = Manager.start_cloud_run(request, manager)

      assert [row] = list_runs(ctx.repo)
      assert row.status == "blocked"
      assert row.reason == "cli_unavailable"
      assert_receive {:delivered, "123", _text}, 5_000
    end

    test "consent_required (scheduled) ledgers a blocked cloud row and delivers guidance", ctx do
      manager = start_manager(ctx)

      block = %{
        params: %{env_id: "proj-web"},
        snapshot: scheduled_snapshot(),
        origin_session_id: "cron_job_x_20260721",
        reason: :consent_required
      }

      assert :ok = Manager.block_scheduled_cloud(block, manager)

      assert [row] = list_runs(ctx.repo)
      assert row.status == "blocked"
      assert row.reason == "consent_required"
      assert row.rail == "cloud"

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "consent_required"
      assert text =~ "approved"
    end
  end

  # --- Poll → terminal ------------------------------------------------------

  describe "poll to terminal" do
    test "READY maps to completed and delivers vendor status + URL + diff hint", ctx do
      manager = start_manager(ctx)

      stub =
        cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:pending), status(:ready)])

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      assert row = await_status(ctx.repo, run_id, "completed")
      assert row.reason == nil
      assert row.diagnostics_tail =~ "vendor status: ready"

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "[run #{run_id}]"
      assert text =~ "vendor status: ready"
      assert text =~ @task_url
      assert text =~ "codex cloud diff #{@task_id}"
    end

    test "APPLIED maps to completed with a vendor-applied note", ctx do
      manager = start_manager(ctx)
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:applied)])

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      assert row = await_status(ctx.repo, run_id, "completed")
      assert row.diagnostics_tail =~ "applied"
    end

    test "ERROR maps to failed/:cloud_failed", ctx do
      manager = start_manager(ctx)
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:error)])

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      assert row = await_status(ctx.repo, run_id, "failed")
      assert row.reason == "cloud_failed"
    end

    test "a parse failure re-arms and a later terminal status still completes", ctx do
      manager = start_manager(ctx)

      stub =
        cloud_stub(ctx,
          submit_output: submit_ok(),
          statuses: [{"garbage line with no status\n", 0}, status(:ready)]
        )

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      # The garbage poll did not terminalize (bounded by the deadline, re-armed);
      # the next poll's READY completes it.
      assert await_status(ctx.repo, run_id, "completed")
    end

    test "not-signed-in at poll terminalizes blocked/:cloud_auth (D19)", ctx do
      manager = start_manager(ctx)

      stub =
        cloud_stub(ctx,
          submit_output: submit_ok(),
          statuses: [{not_signed_in(), 1}]
        )

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      assert row = await_status(ctx.repo, run_id, "blocked")
      assert row.reason == "cloud_auth"
    end

    test "the poll deadline terminalizes blocked/:poll_deadline with the task URL", ctx do
      # Deadline shorter than the poll interval: the first tick trips it before any
      # terminal status is reached (all statuses stay pending).
      manager = start_manager(ctx, cloud_poll_max_ms: 5)
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:pending)])

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      assert row = await_status(ctx.repo, run_id, "blocked")
      assert row.reason == "poll_deadline"
      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ "poll_deadline"
      assert text =~ @task_url
    end
  end

  # --- stop_tracking + cancel ----------------------------------------------

  describe "stop_tracking" do
    test "cancels tracking, blocks the run, and delivers the URL without claiming a stop", ctx do
      manager = start_manager(ctx, cloud_poll_ms: 10_000)
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:pending)])

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)
      assert {:ok, @task_url} = Manager.stop_tracking(run_id, manager)

      assert row = await_status(ctx.repo, run_id, "blocked")
      assert row.reason == "tracking_stopped"

      # The run left the manager's tracking map (timer cancelled).
      refute Map.has_key?(:sys.get_state(manager).runs, run_id)

      assert_receive {:delivered, "123", text}, 5_000
      assert text =~ @task_url
      assert text =~ "keeps running"
    end

    test "an unknown id is not_found", ctx do
      manager = start_manager(ctx)
      assert {:error, :not_found} = Manager.stop_tracking("hr_000000000000", manager)
    end

    # M29 §17.6(d) branch 3: a client-owned origin has no framework wire, so the
    # abandoned run dead-letters by its OWN name rather than being handed to a text
    # path that could only report `{:unsupported_delivery_platform, "acp"}`.
    test "a client-owned origin dead-letters as :tracking_stopped instead of delivering", ctx do
      manager = start_manager(ctx, cloud_poll_ms: 10_000)
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:pending)])

      request = Map.put(cloud_request(stub), :snapshot, client_snapshot())
      assert {:ok, run_id} = Manager.start_cloud_run(request, manager)
      assert {:ok, @task_url} = Manager.stop_tracking(run_id, manager)

      assert row = await_status(ctx.repo, run_id, "blocked")
      assert row.reason == "tracking_stopped"

      assert dead = await_delivery_status(ctx.repo, run_id, "dead_letter")
      assert dead.last_delivery_error =~ "tracking_stopped"
      refute dead.last_delivery_error =~ "unsupported_delivery_platform"
      refute_receive {:delivered, _destination, _text}, 200
    end
  end

  describe "cancel on a cloud run" do
    test "returns vendor_cancel_unsupported and polling continues", ctx do
      manager = start_manager(ctx, cloud_poll_ms: 10_000)
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:pending)])

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      assert {:error, {:vendor_cancel_unsupported, @task_url}} =
               Manager.cancel(run_id, :owner, manager)

      # Polling continues: the run stays active in the manager and on the ledger.
      assert %{cloud: true} = Map.get(:sys.get_state(manager).runs, run_id)
      assert {:ok, %{status: "polling"}} = Ledger.get(run_id, server: ctx.repo)

      assert {:ok, _} = Manager.stop_tracking(run_id, manager)
    end
  end

  describe "stop_all" do
    test "skips cloud runs (no vendor cancel) and counts local only", ctx do
      manager = start_manager(ctx, cloud_poll_ms: 10_000)
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:pending)])

      assert {:ok, run_id} = Manager.start_cloud_run(cloud_request(stub), manager)

      assert %{cancelled: 0} = Manager.stop_all(manager)
      assert {:ok, %{status: "polling"}} = Ledger.get(run_id, server: ctx.repo)

      assert {:ok, _} = Manager.stop_tracking(run_id, manager)
    end
  end

  # --- Boot reconciliation --------------------------------------------------

  describe "boot reconciliation" do
    test "a submitting row WITH a task id is promoted and polled to completion", ctx do
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:ready)])
      run_id = seed_cloud_run(ctx, "submitting", task_id: @task_id, task_url: @task_url)

      manager = start_manager(ctx, timer_enabled: true, find_executable: resolver(stub))
      _ = :sys.get_state(manager)

      assert await_status(ctx.repo, run_id, "completed")
    end

    test "a polling row past its next_poll_at re-arms and polls to completion", ctx do
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:ready)])
      now = DateTime.utc_now()

      run_id =
        seed_cloud_run(ctx, "polling",
          task_id: @task_id,
          task_url: @task_url,
          next_poll_at: DateTime.add(now, -1, :second),
          poll_deadline: DateTime.add(now, 300, :second)
        )

      manager = start_manager(ctx, timer_enabled: true, find_executable: resolver(stub))
      _ = :sys.get_state(manager)

      assert await_status(ctx.repo, run_id, "completed")
    end

    test "a polling row past its poll_deadline is blocked/:poll_deadline", ctx do
      stub = cloud_stub(ctx, submit_output: submit_ok(), statuses: [status(:pending)])
      now = DateTime.utc_now()

      run_id =
        seed_cloud_run(ctx, "polling",
          task_id: @task_id,
          task_url: @task_url,
          next_poll_at: DateTime.add(now, -10, :second),
          poll_deadline: DateTime.add(now, -1, :second)
        )

      manager = start_manager(ctx, timer_enabled: true, find_executable: resolver(stub))
      _ = :sys.get_state(manager)

      assert row = await_status(ctx.repo, run_id, "blocked")
      assert row.reason == "poll_deadline"
    end
  end

  # --- Manager construction -------------------------------------------------

  defp start_manager(ctx, overrides \\ []) do
    name = :"harness_cloud_manager_#{System.unique_integer([:positive])}"

    opts =
      [
        name: name,
        repo: ctx.repo,
        run_supervisor: ctx.run_sup,
        command_supervisor: ctx.host_sup,
        artifacts_opts: [runs_root: ctx.runs_root, quota_gb: 1000, min_free_gb: 0],
        delivery_opts: [adapter: RecordingAdapter],
        # `Harness.Env` requires USER; seed it so the cloud rail's tests never read
        # ambient host state (hermetic-tests rule).
        user: "harness-op",
        timer_enabled: false,
        cloud_poll_ms: @poll_ms,
        cloud_poll_max_ms: 5_000,
        cloud_submit_timeout_ms: 5_000,
        cloud_status_timeout_ms: 5_000
      ]
      |> Keyword.merge(overrides)

    start_supervised!(%{id: name, start: {Manager, :start_link, [opts]}})
    name
  end

  # --- Requests + stubs -----------------------------------------------------

  defp cloud_request(stub, param_overrides \\ %{}) do
    %{
      params: Map.merge(%{query: "fix the flaky test", env_id: "proj-web"}, param_overrides),
      snapshot: chat_snapshot(),
      origin_session_id: "telegram:123:root",
      ctx: %{find_executable: resolver(stub)}
    }
  end

  defp chat_snapshot do
    %{
      origin_kind: "chat",
      delivery_mode: "channel",
      platform: "telegram",
      destination: "123",
      thread: nil,
      send_opts: nil,
      parent_job_id: nil,
      client_origin: nil
    }
  end

  defp client_snapshot do
    %{
      chat_snapshot()
      | platform: "acp",
        destination: "sess-1",
        client_origin: %{
          "identity" => "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e",
          "cwd" => "/repo",
          "reply_context" => "[Context] channel=abc"
        }
    }
  end

  defp scheduled_snapshot do
    %{chat_snapshot() | origin_kind: "scheduled", parent_job_id: "job_x"}
  end

  defp cloud_stub(ctx, opts), do: FakeCloudCli.write!(ctx.stub_dir, opts)

  defp resolver(nil), do: fn _name -> nil end
  defp resolver(stub), do: fn "codex" -> stub end

  defp submit_ok, do: @task_url <> "\n"

  defp not_signed_in do
    "Not signed in. Please run 'codex login' to sign in with ChatGPT, then re-run 'codex cloud'.\n"
  end

  defp status(:pending),
    do: {"[PENDING] Fix the flaky test\nweb-app  •  12 seconds ago\nno diff\n", 1}

  defp status(:ready),
    do: {"[READY] Fix the flaky test\nweb-app  •  2 minutes ago\n+42/-8 • 3 files\n", 0}

  defp status(:applied),
    do: {"[APPLIED] Fix the flaky test\nweb-app  •  5 minutes ago\n+42/-8 • 3 files\n", 1}

  defp status(:error), do: {"[ERROR] Fix the flaky test\nweb-app  •  3 minutes ago\nno diff\n", 1}

  # --- Seeds ----------------------------------------------------------------

  # A run only enters the ledger via admission (`starting`/`submitting`), so a
  # `polling` seed is admitted `submitting` with its task id then promoted through
  # the guarded transition — the same path the live rail uses.
  defp seed_cloud_run(ctx, target_status, fields) do
    fields = Map.new(fields)
    id = Ledger.generate_id()
    artifacts_dir = Path.join(ctx.runs_root, id)
    File.mkdir_p!(artifacts_dir)

    attrs =
      %{
        id: id,
        vendor: "codex_cloud",
        rail: "cloud",
        status: "submitting",
        cwd: "cloud:proj-web",
        worktree_root: "cloud:proj-web",
        lock_roots: [],
        artifacts_dir: artifacts_dir,
        resumable: false,
        origin_kind: "chat",
        origin_session_id: "telegram:123:root",
        delivery_mode: "channel",
        platform: "telegram",
        destination: "123"
      }
      |> Map.merge(Map.take(fields, [:task_id, :task_url]))

    {:ok, _row} = Ledger.admit(attrs, server: ctx.repo)
    maybe_promote(ctx, id, target_status, fields)
    id
  end

  defp maybe_promote(ctx, id, "polling", fields) do
    poll = Map.take(fields, [:task_id, :task_url, :next_poll_at, :poll_deadline])
    {:ok, _row} = Ledger.mark_polling(id, poll, server: ctx.repo)
  end

  defp maybe_promote(_ctx, _id, "submitting", _fields), do: :ok

  # --- Bounded polling (never a fixed coordination sleep) -------------------

  defp await_status(repo, run_id, status) do
    poll(fn ->
      case Ledger.get(run_id, server: repo) do
        {:ok, %{status: ^status} = row} -> {:halt, row}
        _other -> :cont
      end
    end) || flunk("cloud run #{run_id} did not reach status #{status}")
  end

  defp await_delivery_status(repo, run_id, status) do
    poll(fn ->
      case Ledger.get(run_id, server: repo) do
        {:ok, %{delivery_status: ^status} = row} -> {:halt, row}
        _other -> :cont
      end
    end) || flunk("cloud run #{run_id} never reached delivery status #{status}")
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

  defp ok({:ok, _} = _reply), do: :ok
  defp ok(other), do: flunk("expected {:ok, _}, got #{inspect(other)}")

  # --- Supervisors ----------------------------------------------------------

  defp start_run_supervisor do
    name = :"harness_cloud_run_sup_#{System.unique_integer([:positive])}"
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

  defp restore(nil), do: Application.delete_env(:fermix_core, :harness)
  defp restore(value), do: Application.put_env(:fermix_core, :harness, value)
end
