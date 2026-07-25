defmodule FermixCore.Harness.RunTest do
  # async: false — each test spawns a real OS process group via a per-test
  # CommandHost supervisor (never the global one) and drives a per-test Repo; the
  # `[fermix_core.harness]` app-env baseline is established here, not leaked.
  # All artifacts land under SafeRm tmp dirs; the vendor CLI is a generated stub.
  use ExUnit.Case, async: false

  alias FermixCore.Harness.Adapters.ClaudeHeadless
  alias FermixCore.Harness.Adapters.CodexExec
  alias FermixCore.Harness.Ledger
  alias FermixCore.Harness.Run
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.FakeVendorCli

  @fixtures Path.expand("../../fixtures/harness", __DIR__)
  @codex_session "019f7d3f-3f21-7482-8c91-749fb4713417"
  @claude_session "19191a60-736f-4477-a4ac-0c0b3641cbcb"
  @report_fields ~w(reason exit_code usage result_text diagnostics_tail
                    framing_errors vendor_session_id artifact_truncated)a

  # Bounded liveness polling (never a fixed coordination sleep), mirroring
  # command_host_stream_test.
  @poll_max 100
  @poll_ms 20

  setup do
    prior = Application.get_env(:fermix_core, :harness)
    Application.put_env(:fermix_core, :harness, max_active: 100)

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-harness-run-#{unique}.db")
    repo = :"harness_run_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    sup = start_host_sup()
    workspace = FermixTestSupport.SafeRm.make_tmp_dir!("harness-run-workspace")
    stub_dir = FermixTestSupport.SafeRm.make_tmp_dir!("harness-run-stub")
    artifacts_base = FermixTestSupport.SafeRm.make_tmp_dir!("harness-run-artifacts")
    home = FermixTestSupport.SafeRm.make_tmp_dir!("harness-run-home")
    runs_root = Path.join(artifacts_base, "harness/runs")
    File.mkdir_p!(runs_root)

    on_exit(fn ->
      restore_harness(prior)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)

      Enum.each(
        [workspace, stub_dir, artifacts_base, home],
        &FermixTestSupport.SafeRm.rm_rf!/1
      )
    end)

    %{
      repo: repo,
      sup: sup,
      workspace: workspace,
      stub_dir: stub_dir,
      runs_root: runs_root,
      home: home
    }
  end

  describe "happy path" do
    test "codex fixture: completed with session id, usage, result artifact, spool", ctx do
      stub =
        FakeVendorCli.write!(ctx.stub_dir,
          lines: fixture_lines("codex_exec_success.jsonl"),
          result_text: "codex-final-answer"
        )

      {run_id, pid} = start_run(ctx, CodexExec, stub, %{})

      assert_receive {:harness_report_terminal, ^run_id, "completed", fields}, 5_000
      refute_run_alive(pid)

      assert fields.vendor_session_id == @codex_session
      assert Map.has_key?(fields.usage, "input_tokens")
      assert fields.result_text == "codex-final-answer"
      assert fields.reason == nil
      assert fields.exit_code == 0
      assert fields.artifact_truncated == false

      spool = spool_path(ctx.runs_root, run_id)
      assert File.exists?(spool)
      assert File.read!(spool) =~ "thread.started"

      assert {:ok, row} = Ledger.get(run_id, server: ctx.repo)
      assert row.vendor_session_id == @codex_session
      assert %DateTime{} = row.started_at
      assert %DateTime{} = row.first_event_at
    end

    test "claude fixture: completed with session id, usage, result text, spool", ctx do
      stub =
        FakeVendorCli.write!(ctx.stub_dir, lines: fixture_lines("claude_stream_success.jsonl"))

      {run_id, pid} = start_run(ctx, ClaudeHeadless, stub, %{})

      assert_receive {:harness_report_terminal, ^run_id, "completed", fields}, 5_000
      refute_run_alive(pid)

      assert fields.vendor_session_id == @claude_session
      assert Map.has_key?(fields.usage, "total_cost_usd")
      assert fields.result_text == "ok"
      assert fields.exit_code == 0

      spool = spool_path(ctx.runs_root, run_id)
      assert File.exists?(spool)
      assert File.read!(spool) =~ @claude_session

      # Claude has no vendor `-o` file, so the Run persists the stream-sourced
      # result to `result.txt` — the file the delivery/inline-await/get paths read.
      assert File.read!(result_path(ctx.runs_root, run_id)) == "ok"
    end
  end

  describe "failure classification" do
    test "a non-zero exit is failed/:exit_<code> regardless of events", ctx do
      stub =
        FakeVendorCli.write!(ctx.stub_dir,
          lines: [~s({"type":"thread.started","thread_id":"t1"}), ~s({"type":"turn.started"})],
          exit_code: 7
        )

      {run_id, pid} = start_run(ctx, CodexExec, stub, %{})

      assert_receive {:harness_report_terminal, ^run_id, "failed", fields}, 5_000
      refute_run_alive(pid)
      assert fields.reason == "exit_7"
      assert fields.exit_code == 7
    end

    test "an oversized line breaches the framing budget → failed/:protocol", ctx do
      stub =
        FakeVendorCli.write!(ctx.stub_dir,
          lines: [String.duplicate("x", 200)],
          exit_code: 0
        )

      # max_event_bytes 64 + zero framing tolerance: the 200-byte line is a
      # framing violation on arrival, so push/2 returns {:error, {:protocol, …}}
      # and the run cancels itself and terminalizes failed/:protocol.
      {run_id, pid} =
        start_run(ctx, CodexExec, stub, %{max_event_bytes: 64, max_framing_errors: 0})

      assert_receive {:harness_report_terminal, ^run_id, "failed", fields}, 5_000
      refute_run_alive(pid)
      assert fields.reason == "protocol"
      assert fields.framing_errors >= 1
    end
  end

  describe "stall watchdogs (advisory notices, run continues)" do
    test "the first-event watchdog fires the auth/config notice when nothing streams", ctx do
      stub =
        FakeVendorCli.write!(ctx.stub_dir,
          lines: [~s({"type":"thread.started","thread_id":"t1"})],
          hang_after: 0
        )

      {_run_id, pid} =
        start_run(ctx, CodexExec, stub, %{first_event_ms: 120, inactivity_ms: 30_000})

      assert_receive {:notice, text}, 5_000
      assert text =~ "auth"
      assert text =~ "config"

      stop_run(pid)
    end

    test "the inactivity watchdog fires after events stop arriving", ctx do
      stub =
        FakeVendorCli.write!(ctx.stub_dir,
          lines: [
            ~s({"type":"thread.started","thread_id":"t1"}),
            ~s({"type":"turn.started"}),
            ~s({"type":"item.completed","item":{"id":"i","type":"agent_message","text":"hi"}})
          ],
          hang_after: 2
        )

      {_run_id, pid} =
        start_run(ctx, CodexExec, stub, %{first_event_ms: 30_000, inactivity_ms: 150})

      assert_receive {:notice, text}, 5_000
      assert text =~ "activity"

      stop_run(pid)
    end
  end

  describe "wall clock" do
    test "the host timeout terminal maps to failed/:timeout via Timeouts.expired", ctx do
      attach_expired()

      stub =
        FakeVendorCli.write!(ctx.stub_dir,
          lines: [~s({"type":"thread.started","thread_id":"t1"})],
          hang_after: 0
        )

      {run_id, pid} =
        start_run(ctx, CodexExec, stub, %{
          wall_clock_ms: 300,
          first_event_ms: 30_000,
          inactivity_ms: 30_000
        })

      assert_receive {:harness_report_terminal, ^run_id, "failed", fields}, 5_000
      refute_run_alive(pid)
      assert fields.reason == "timeout"

      assert_receive {:expired, %{ms: 300}, meta}, 5_000
      assert meta.name == :harness_wall_clock
      assert meta.session_id == "harness_" <> run_id
    end
  end

  describe "cancellation" do
    test "cancel(:owner) mid-stream terminalizes cancelled", ctx do
      stub =
        FakeVendorCli.write!(ctx.stub_dir,
          lines: [
            ~s({"type":"thread.started","thread_id":"#{@codex_session}"}),
            ~s({"type":"turn.started"}),
            ~s({"type":"item.completed","item":{"id":"i","type":"agent_message","text":"hi"}})
          ],
          hang_after: 2
        )

      {run_id, pid} = start_run(ctx, CodexExec, stub, %{})

      # Deterministic proof the run is mid-stream: the first event's session id
      # has been persisted before we cancel (bounded poll, never a fixed sleep).
      assert await_session_id(ctx.repo, run_id) == @codex_session

      assert :ok = Run.cancel(pid, :owner)
      assert_receive {:harness_report_terminal, ^run_id, "cancelled", fields}, 5_000
      refute_run_alive(pid)
      assert fields.reason == nil
    end
  end

  describe "artifact spool bound" do
    test "a huge stream truncates the spool but the run completes", ctx do
      middle =
        for n <- 1..40, do: ~s({"type":"item.completed","item":{"id":"i#{n}","type":"reasoning"}})

      lines =
        [~s({"type":"thread.started","thread_id":"#{@codex_session}"})] ++
          middle ++
          [~s({"type":"turn.completed","usage":{"input_tokens":1}})]

      # spool cap 100 bytes, host cap left large so the soft cap governs: spooling
      # stops, artifact_truncated is set, and the run runs on to its terminal event.
      {run_id, pid} =
        start_run(ctx, CodexExec, stub_from(ctx, lines), %{
          spool_limit_bytes: 100,
          max_output_bytes: 10_000_000
        })

      assert_receive {:harness_report_terminal, ^run_id, "completed", fields}, 5_000
      refute_run_alive(pid)
      assert fields.artifact_truncated == true

      spool = spool_path(ctx.runs_root, run_id)
      assert File.exists?(spool)
      assert File.stat!(spool).size <= 300
    end
  end

  describe "progress telemetry" do
    test "emits [:fermix, :harness, :progress] with the run session id once throttle elapses",
         ctx do
      attach_progress()

      lines = [
        ~s({"type":"thread.started","thread_id":"#{@codex_session}"}),
        ~s({"type":"turn.started"}),
        ~s({"type":"item.completed","item":{"id":"i","type":"reasoning"}}),
        ~s({"type":"turn.completed","usage":{"input_tokens":1}})
      ]

      {run_id, pid} = start_run(ctx, CodexExec, stub_from(ctx, lines), %{progress_throttle_ms: 0})

      assert_receive {:harness_report_terminal, ^run_id, "completed", _fields}, 5_000
      refute_run_alive(pid)

      assert_receive {:harness_progress, meta}, 5_000
      assert meta.session_id == "harness_" <> run_id
    end
  end

  describe "report_terminal field completeness" do
    test "every terminal report carries the full field set", ctx do
      stub =
        FakeVendorCli.write!(ctx.stub_dir,
          lines: fixture_lines("codex_exec_success.jsonl"),
          result_text: "done"
        )

      {run_id, _pid} = start_run(ctx, CodexExec, stub, %{})

      assert_receive {:harness_report_terminal, ^run_id, "completed", fields}, 5_000

      assert Enum.sort(Map.keys(fields)) == Enum.sort(@report_fields)
      assert is_binary(fields.vendor_session_id)
      assert is_map(fields.usage)
      assert is_binary(fields.result_text)
      assert is_list(fields.diagnostics_tail)
      assert is_integer(fields.framing_errors)
      assert is_integer(fields.exit_code)
      assert is_boolean(fields.artifact_truncated)
      assert fields.reason == nil
    end
  end

  # --- Helpers ------------------------------------------------------------

  defp start_run(ctx, adapter, stub_path, overrides) do
    plan = build_plan(adapter, stub_path, ctx.workspace)
    row = admit_row(ctx, adapter.vendor(), plan.cwd)
    # Captured in the closure so the Run's spawned notice process targets the
    # test process (a process-dictionary read there would see the wrong pid).
    test = self()

    args =
      Map.merge(
        %{
          row: row,
          plan: plan,
          prompt: "do the work",
          adapter: adapter,
          manager: test,
          repo: ctx.repo,
          runs_root: ctx.runs_root,
          home: ctx.home,
          command_supervisor: ctx.sup,
          wall_clock_ms: 30_000,
          first_event_ms: 5_000,
          inactivity_ms: 5_000,
          notice_fn: fn text -> send(test, {:notice, text}) end
        },
        overrides
      )

    {:ok, pid} = Run.start_link(args)
    {row.id, pid}
  end

  defp build_plan(adapter, stub_path, cwd) do
    ctx = %{
      cwd: cwd,
      sandbox_config: %{mode: :strict, workspace_root: cwd, allowed_roots: []},
      find_executable: fn _name -> stub_path end
    }

    {:ok, plan} = adapter.plan(%{}, ctx)
    plan
  end

  defp admit_row(ctx, vendor, cwd) do
    id = Ledger.generate_id()
    unique = System.unique_integer([:positive])

    attrs = %{
      id: id,
      vendor: vendor,
      rail: "local",
      status: "starting",
      cwd: cwd,
      worktree_root: cwd,
      lock_roots: ["#{cwd}-lock-#{unique}"],
      artifacts_dir: Path.join(ctx.runs_root, id),
      origin_kind: "chat",
      origin_session_id: "main-#{unique}",
      delivery_mode: "reply"
    }

    {:ok, row} = Ledger.admit(attrs, server: ctx.repo)
    row
  end

  defp stub_from(ctx, lines), do: FakeVendorCli.write!(ctx.stub_dir, lines: lines)

  defp fixture_lines(name) do
    @fixtures |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
  end

  defp spool_path(runs_root, run_id), do: Path.join([runs_root, run_id, "events.jsonl"])

  defp result_path(runs_root, run_id), do: Path.join([runs_root, run_id, "result.txt"])

  defp await_session_id(repo, run_id) do
    Enum.reduce_while(1..@poll_max, nil, fn _attempt, _acc ->
      case Ledger.get(run_id, server: repo) do
        {:ok, %{vendor_session_id: sid}} when is_binary(sid) -> {:halt, sid}
        _pending -> poll_wait()
      end
    end)
  end

  defp poll_wait do
    Process.sleep(@poll_ms)
    {:cont, nil}
  end

  defp refute_run_alive(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> flunk("run #{inspect(pid)} did not stop within 5s")
    end
  end

  defp stop_run(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp attach_expired do
    test_pid = self()
    handler = "harness-run-expired-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:fermix, :timeout, :expired],
      fn _event, measurements, meta, _ -> send(test_pid, {:expired, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp attach_progress do
    test_pid = self()
    handler = "harness-run-progress-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:fermix, :harness, :progress],
      fn _event, _measurements, meta, _ -> send(test_pid, {:harness_progress, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp start_host_sup do
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

  defp restore_harness(nil), do: Application.delete_env(:fermix_core, :harness)
  defp restore_harness(value), do: Application.put_env(:fermix_core, :harness, value)
end
