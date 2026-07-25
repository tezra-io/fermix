defmodule FermixCore.Harness.LedgerTest do
  # async: false — establishes a known `[fermix_core.harness]` app-env baseline
  # (`max_active`) so the admission-capacity assertions do not read leaked global
  # env, and restores it on exit (hermetic-config discipline).
  use ExUnit.Case, async: false

  alias FermixCore.Harness.Ledger
  alias FermixCore.Harness.Workspace
  alias FermixCore.Memory.Repo

  setup do
    prev_harness = Application.get_env(:fermix_core, :harness)
    Application.put_env(:fermix_core, :harness, max_active: 2)

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-harness-ledger-#{unique}.db")
    repo_name = :"harness_ledger_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      case prev_harness do
        nil -> Application.delete_env(:fermix_core, :harness)
        value -> Application.put_env(:fermix_core, :harness, value)
      end

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name}
  end

  test "generate_id yields the hr_ + 12-hex shape" do
    id = Ledger.generate_id()
    assert id =~ ~r/^hr_[0-9a-f]{12}$/
    refute Ledger.generate_id() == Ledger.generate_id()
  end

  test "admit inserts a starting run with a generated id", %{repo: repo} do
    assert {:ok, run} = Ledger.admit(base_attrs(), server: repo)

    assert run.id =~ ~r/^hr_[0-9a-f]{12}$/
    assert run.status == "starting"
    assert run.vendor == "codex"
    assert run.rail == "local"
    assert run.lock_roots == ["/repo"]
    assert run.resumable == true
    assert run.delivery_status == "pending"
    assert run.delivery_attempts == 0
    assert run.framing_errors == 0
    assert run.artifact_truncated == false
    assert %DateTime{} = run.created_at
    assert is_nil(run.completed_at)

    assert {:ok, ^run} = Ledger.get(run.id, server: repo)
  end

  test "continuation_depth defaults to 0 and round-trips a launched chain depth", %{repo: repo} do
    assert {:ok, plain} = Ledger.admit(base_attrs(), server: repo)
    assert plain.continuation_depth == 0

    # A distinct lock root: the first row is still active and holds "/repo".
    attrs =
      base_attrs(%{
        continuation_depth: 2,
        worktree_root: "/repo-continued",
        lock_roots: ["/repo-continued"]
      })

    assert {:ok, continued} = Ledger.admit(attrs, server: repo)
    assert continued.continuation_depth == 2
    assert {:ok, %{continuation_depth: 2}} = Ledger.get(continued.id, server: repo)
  end

  test "admit keeps a caller-pinned id", %{repo: repo} do
    attrs = Map.put(base_attrs(), :id, "hr_deadbeef0001")
    assert {:ok, run} = Ledger.admit(attrs, server: repo)
    assert run.id == "hr_deadbeef0001"
  end

  test "the nested-cwd race admits exactly one of two overlapping roots", %{repo: repo} do
    # ExUnit runs from the app dir; derive the umbrella worktree root, then two
    # sibling app dirs beneath it.
    assert {:ok, worktree_root} = Workspace.lock_root(File.cwd!(), supervised: false)
    cwd_a = Path.join(worktree_root, "apps/fermix_core")
    cwd_b = Path.join(worktree_root, "apps/fermix_web")

    assert {:ok, root_a} = Workspace.lock_root(cwd_a, supervised: false)
    assert {:ok, root_b} = Workspace.lock_root(cwd_b, supervised: false)

    # Two sibling app dirs of one worktree collapse onto the same lock root.
    assert root_a == root_b

    attrs_a = %{base_attrs() | worktree_root: root_a, lock_roots: [root_a], cwd: cwd_a}
    attrs_b = %{base_attrs() | worktree_root: root_b, lock_roots: [root_b], cwd: cwd_b}

    task_a = Task.async(fn -> Ledger.admit(attrs_a, server: repo) end)
    task_b = Task.async(fn -> Ledger.admit(attrs_b, server: repo) end)

    results = [Task.await(task_a, 5_000), Task.await(task_b, 5_000)]

    oks = for {:ok, run} <- results, do: run
    locked = for {:error, reason} <- results, do: reason

    assert length(oks) == 1
    assert locked == [{:workspace_locked, root_a}]
  end

  test "admission refuses a lock root already held by an active run", %{repo: repo} do
    assert {:ok, _a} = Ledger.admit(base_attrs(%{lock_roots: ["/repo"]}), server: repo)

    assert {:error, {:workspace_locked, "/repo"}} =
             Ledger.admit(base_attrs(%{lock_roots: ["/repo"]}), server: repo)
  end

  test "admission enforces max_active across distinct roots", %{repo: repo} do
    assert {:ok, _a} =
             Ledger.admit(base_attrs(%{lock_roots: ["/ra"], worktree_root: "/ra"}), server: repo)

    assert {:ok, _b} =
             Ledger.admit(base_attrs(%{lock_roots: ["/rb"], worktree_root: "/rb"}), server: repo)

    assert {:error, :max_active} =
             Ledger.admit(base_attrs(%{lock_roots: ["/rc"], worktree_root: "/rc"}), server: repo)
  end

  test "terminalize releases the lock and frees capacity", %{repo: repo} do
    assert {:ok, a} =
             Ledger.admit(base_attrs(%{lock_roots: ["/r1"], worktree_root: "/r1"}), server: repo)

    assert {:ok, _b} =
             Ledger.admit(base_attrs(%{lock_roots: ["/r2"], worktree_root: "/r2"}), server: repo)

    # At capacity (2) and /r1 is held.
    assert {:error, :max_active} =
             Ledger.admit(base_attrs(%{lock_roots: ["/r3"], worktree_root: "/r3"}), server: repo)

    assert {:ok, terminal} =
             Ledger.terminalize(a.id, "completed", %{exit_code: 0}, server: repo)

    assert terminal.status == "completed"
    assert terminal.exit_code == 0
    assert %DateTime{} = terminal.completed_at

    # Capacity freed AND the /r1 lock released.
    assert {:ok, _c} =
             Ledger.admit(base_attrs(%{lock_roots: ["/r1"], worktree_root: "/r1"}), server: repo)
  end

  test "a second terminalize returns already_terminal", %{repo: repo} do
    assert {:ok, run} = Ledger.admit(base_attrs(), server: repo)

    assert {:ok, _} =
             Ledger.terminalize(run.id, "failed", %{reason: "exit_2", exit_code: 2}, server: repo)

    assert {:error, :already_terminal} =
             Ledger.terminalize(run.id, "completed", %{}, server: repo)
  end

  test "terminalize of an unknown run returns not_found", %{repo: repo} do
    assert {:error, :not_found} =
             Ledger.terminalize("hr_000000000000", "completed", %{}, server: repo)
  end

  test "terminalize refuses a non-terminal target status", %{repo: repo} do
    assert {:ok, run} = Ledger.admit(base_attrs(), server: repo)

    # "polling" is an ACTIVE status: terminalizing to it would leave the run
    # active (still holding its lock + capacity) with completed_at set.
    assert {:error, {:invalid_terminal_status, "polling"}} =
             Ledger.terminalize(run.id, "polling", %{}, server: repo)

    # The row is untouched: still active, still holding its lock.
    assert {:ok, [only]} = Ledger.active_runs(server: repo)
    assert only.id == run.id
    assert only.status == "starting"
  end

  test "admit refuses a non-starting/submitting status", %{repo: repo} do
    assert {:error, {:invalid_admit_status, "completed"}} =
             Ledger.admit(base_attrs(%{status: "completed"}), server: repo)

    assert {:ok, none} = Ledger.active_runs(server: repo)
    assert none == []
  end

  test "record_progress cannot resurrect a terminal row to an active status", %{repo: repo} do
    assert {:ok, run} = Ledger.admit(base_attrs(), server: repo)
    assert {:ok, _} = Ledger.terminalize(run.id, "completed", %{exit_code: 0}, server: repo)

    # :status is refused on the generic update path — the only legitimate status
    # writer is terminalize. A resurrection attempt fails loud without silently
    # flipping the terminal row back to active (which would re-acquire its lock).
    assert {:error, :status_not_updatable} =
             Ledger.record_progress(run.id, %{status: "running"}, server: repo)

    assert {:ok, reloaded} = Ledger.get(run.id, server: repo)
    assert reloaded.status == "completed"
    assert {:ok, []} = Ledger.active_runs(server: repo)
  end

  test "records vendor session id and material progress", %{repo: repo} do
    assert {:ok, run} = Ledger.admit(base_attrs(), server: repo)

    assert {:ok, _} = Ledger.record_session(run.id, "codex-sess-abc", server: repo)

    at = ~U[2026-07-19 12:00:00Z]

    assert {:ok, _} =
             Ledger.record_progress(run.id, %{first_event_at: at, last_event_at: at},
               server: repo
             )

    assert {:ok, reloaded} = Ledger.get(run.id, server: repo)
    assert reloaded.vendor_session_id == "codex-sess-abc"
    assert DateTime.compare(reloaded.first_event_at, at) == :eq
    assert DateTime.compare(reloaded.last_event_at, at) == :eq
  end

  test "active_runs lists only active rows", %{repo: repo} do
    assert {:ok, a} =
             Ledger.admit(base_attrs(%{lock_roots: ["/ra"], worktree_root: "/ra"}), server: repo)

    assert {:ok, b} =
             Ledger.admit(base_attrs(%{lock_roots: ["/rb"], worktree_root: "/rb"}), server: repo)

    assert {:ok, active} = Ledger.active_runs(server: repo)
    assert Enum.map(active, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])

    assert {:ok, _} = Ledger.terminalize(a.id, "completed", %{}, server: repo)

    assert {:ok, [only]} = Ledger.active_runs(server: repo)
    assert only.id == b.id
  end

  test "pending_deliveries excludes an admitted-but-active run", %{repo: repo} do
    now = ~U[2026-07-19 15:00:00Z]

    # An active run is born with delivery_status 'pending' but has produced no
    # result to deliver — only terminal rows are pending deliveries (§12.3). It
    # must not surface, or the DeliveryWorker would deliver an unfinished run.
    assert {:ok, run} = Ledger.admit(base_attrs(), server: repo)

    assert {:ok, pending} = Ledger.pending_deliveries(now, server: repo)
    refute run.id in Enum.map(pending, & &1.id)

    # Once terminal it becomes a pending delivery.
    assert {:ok, _} = Ledger.terminalize(run.id, "completed", %{}, server: repo)
    assert {:ok, after_term} = Ledger.pending_deliveries(now, server: repo)
    assert run.id in Enum.map(after_term, & &1.id)
  end

  test "pending_deliveries surfaces undelivered runs and mark_delivery clears them", %{repo: repo} do
    now = ~U[2026-07-19 15:00:00Z]

    assert {:ok, run} = Ledger.admit(base_attrs(), server: repo)
    assert {:ok, _} = Ledger.terminalize(run.id, "completed", %{}, server: repo)

    assert {:ok, pending} = Ledger.pending_deliveries(now, server: repo)
    assert run.id in Enum.map(pending, & &1.id)

    assert {:ok, delivered} =
             Ledger.mark_delivery(
               run.id,
               %{delivery_status: "delivered", delivery_attempts: 1, delivered_at: now},
               server: repo
             )

    assert delivered.delivery_status == "delivered"
    assert delivered.delivery_attempts == 1
    assert %DateTime{} = delivered.delivered_at

    assert {:ok, still_pending} = Ledger.pending_deliveries(now, server: repo)
    refute run.id in Enum.map(still_pending, & &1.id)
  end

  test "pending_deliveries honors next_delivery_at scheduling", %{repo: repo} do
    now = ~U[2026-07-19 15:00:00Z]
    future = ~U[2026-07-19 16:00:00Z]

    assert {:ok, run} = Ledger.admit(base_attrs(), server: repo)
    assert {:ok, _} = Ledger.terminalize(run.id, "failed", %{reason: "timeout"}, server: repo)

    assert {:ok, _} =
             Ledger.mark_delivery(run.id, %{delivery_attempts: 1, next_delivery_at: future},
               server: repo
             )

    # Backoff not yet due.
    assert {:ok, none} = Ledger.pending_deliveries(now, server: repo)
    refute run.id in Enum.map(none, & &1.id)

    # Due once the clock reaches the scheduled time.
    assert {:ok, due} = Ledger.pending_deliveries(future, server: repo)
    assert run.id in Enum.map(due, & &1.id)
  end

  test "mark_polling promotes a submitting cloud run and persists the poll schedule", %{
    repo: repo
  } do
    next = ~U[2026-07-20 15:02:00Z]
    deadline = ~U[2026-07-20 16:30:00Z]

    assert {:ok, run} = Ledger.admit(cloud_attrs(), server: repo)
    assert run.status == "submitting"

    assert {:ok, polling} =
             Ledger.mark_polling(
               run.id,
               %{
                 task_id: "task_i_abc123",
                 task_url: "https://chatgpt.com/codex/tasks/task_i_abc123",
                 next_poll_at: next,
                 poll_deadline: deadline
               },
               server: repo
             )

    assert polling.status == "polling"
    assert polling.task_id == "task_i_abc123"
    assert polling.task_url == "https://chatgpt.com/codex/tasks/task_i_abc123"
    assert DateTime.compare(polling.next_poll_at, next) == :eq
    assert DateTime.compare(polling.poll_deadline, deadline) == :eq

    # Still active (polling holds its capacity slot); the terminal writer stays
    # the single terminal authority.
    assert {:ok, [only]} = Ledger.active_runs(server: repo)
    assert only.id == run.id
  end

  test "mark_polling on a terminal row is a guarded no-op (never resurrects it)", %{repo: repo} do
    assert {:ok, run} = Ledger.admit(cloud_attrs(), server: repo)
    assert {:ok, _} = Ledger.terminalize(run.id, "blocked", %{reason: "cloud_auth"}, server: repo)

    assert {:ok, reloaded} =
             Ledger.mark_polling(run.id, %{task_id: "task_i_late"}, server: repo)

    # The guard matched zero rows: status stays terminal, task_id NOT applied.
    assert reloaded.status == "blocked"
    assert reloaded.task_id == nil
    assert {:ok, []} = Ledger.active_runs(server: repo)
  end

  test "list filters by an allowlisted column", %{repo: repo} do
    assert {:ok, _a} =
             Ledger.admit(base_attrs(%{lock_roots: ["/ra"], worktree_root: "/ra"}), server: repo)

    assert {:ok, b} =
             Ledger.admit(
               base_attrs(%{lock_roots: ["/rb"], worktree_root: "/rb", vendor: "claude"}),
               server: repo
             )

    assert {:ok, [only]} = Ledger.list(%{vendor: "claude"}, server: repo)
    assert only.id == b.id
  end

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        vendor: "codex",
        rail: "local",
        status: "starting",
        cwd: "/repo/apps/core",
        worktree_root: "/repo",
        lock_roots: ["/repo"],
        artifacts_dir: "/repo/.fermix/artifacts/run",
        origin_kind: "chat",
        origin_session_id: "main-1",
        delivery_mode: "reply"
      },
      overrides
    )
  end

  defp cloud_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        vendor: "codex_cloud",
        rail: "cloud",
        status: "submitting",
        cwd: "cloud:proj-web",
        worktree_root: "cloud:proj-web",
        lock_roots: [],
        artifacts_dir: "/repo/.fermix/artifacts/cloud-run",
        resumable: false,
        origin_kind: "chat",
        origin_session_id: "main-1",
        delivery_mode: "reply"
      },
      overrides
    )
  end
end
