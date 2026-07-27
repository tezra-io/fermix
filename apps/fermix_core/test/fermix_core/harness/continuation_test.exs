defmodule FermixCore.Harness.ContinuationTest do
  # Pure notice composition, the chain-depth predicates, and dispatcher
  # resolution. async: false — the dispatcher-resolution tests set the global
  # `:harness_continuation_dispatcher` app env (config/test.exs pins it to nil)
  # and restore it, so no async test may observe the mutation.
  use ExUnit.Case, async: false

  alias FermixCore.Harness.Continuation

  # `dispatch/4` runs the dispatcher inside the delivery watchdog's own process, so
  # the doubles report to the sink pid the test stashes in app env (safe under
  # `async: false`) rather than to `self()`.
  defmodule OkDispatcher do
    def dispatch(notice) do
      case Application.get_env(:fermix_core, :harness_test_continuation_sink) do
        pid when is_pid(pid) -> send(pid, {:dispatched, notice})
        _absent -> :ok
      end

      :ok
    end
  end

  defmodule FailingDispatcher do
    def dispatch(_notice), do: {:error, :nope}
  end

  defmodule NotADispatcher do
    def something_else, do: :ok
  end

  defmodule WedgedDispatcher do
    def dispatch(_notice), do: Process.sleep(:infinity)
  end

  defmodule CrashingDispatcher do
    def dispatch(_notice), do: raise("re-ingest blew up")
  end

  setup do
    prior = Application.get_env(:fermix_core, :harness_continuation_dispatcher)
    Application.put_env(:fermix_core, :harness_test_continuation_sink, self())

    on_exit(fn ->
      Application.put_env(:fermix_core, :harness_continuation_dispatcher, prior)
      Application.delete_env(:fermix_core, :harness_test_continuation_sink)
    end)

    :ok
  end

  describe "continuable?/1 and depth_capped?/1" do
    test "a chat origin inside the cap continues" do
      assert Continuation.continuable?(row())
      refute Continuation.depth_capped?(row())
    end

    test "a scheduled origin never continues and is never cap-noted" do
      scheduled = row(%{origin_kind: "scheduled"})

      refute Continuation.continuable?(scheduled)
      refute Continuation.depth_capped?(scheduled)

      refute Continuation.continuable?(%{
               scheduled
               | continuation_depth: Continuation.max_depth()
             })

      refute Continuation.depth_capped?(%{
               scheduled
               | continuation_depth: Continuation.max_depth()
             })
    end

    test "the last continuable depth is max_depth - 1" do
      assert Continuation.continuable?(row(%{continuation_depth: Continuation.max_depth() - 1}))
      refute Continuation.continuable?(row(%{continuation_depth: Continuation.max_depth()}))
      assert Continuation.depth_capped?(row(%{continuation_depth: Continuation.max_depth()}))
    end

    test "an owner-cancelled run never continues (the kill switch is not undone)" do
      refute Continuation.continuable?(row(%{status: "cancelled", reason: nil}))
    end

    test "an abandoned cloud run never continues" do
      refute Continuation.continuable?(
               row(%{status: "blocked", reason: "tracking_stopped", vendor: "codex_cloud"})
             )
    end

    test "a genuine failure still continues so the agent can react to it" do
      assert Continuation.continuable?(row(%{status: "failed", reason: "exit_1"}))
      assert Continuation.continuable?(row(%{status: "blocked", reason: "workspace_denied"}))
    end
  end

  describe "notice_text/2" do
    test "a completed run carries the tag, the vendor line, the result, and the closing" do
      text = Continuation.notice_text(row(), "All tests pass.")

      assert text ==
               "[coding run hr_000000000001 finished]\n" <>
                 "codex · completed · /repo/apps/core\n" <>
                 "All tests pass.\n" <>
                 "Continue the request this run was for; if it is already satisfied, " <>
                 "just report the outcome."
    end

    test "a failed run carries the reason and diagnostics instead of a result" do
      text =
        Continuation.notice_text(
          row(%{status: "failed", reason: "exit_1", diagnostics_tail: "error: boom"}),
          nil
        )

      assert text =~ "codex · failed · /repo/apps/core"
      assert text =~ "reason: exit_1"
      assert text =~ "error: boom"
    end

    # Regression: a claude auth failure reaches the ledger as a bare `exit_1` with
    # an empty diagnostics tail (the vendor reports it as well-formed JSON, which
    # `EventStream` counts as an event, not a diagnostic). Without the vendor's own
    # text the agent cannot tell auth from a crash, so it re-launches into the same
    # wall — which is exactly what happened on 2026-07-26.
    test "a failed run leads with the vendor's own error text when it has one" do
      text =
        Continuation.notice_text(
          row(%{status: "failed", reason: "exit_1", diagnostics_tail: nil}),
          "Not logged in · Please run /login"
        )

      assert text =~ "Not logged in · Please run /login"
      assert text =~ "reason: exit_1"

      vendor_at = :binary.match(text, "Not logged in") |> elem(0)
      reason_at = :binary.match(text, "reason: exit_1") |> elem(0)
      assert vendor_at < reason_at, "the vendor's diagnosis must lead the body"
    end

    # The context the agent needs to take a stance. Deliberately NOT a router:
    # both moves are named as legitimate and the agent judges from the failure
    # text, so no reason has to be classified as retryable or terminal.
    test "a failed run closes by naming the decision, not by prescribing a branch" do
      text =
        Continuation.notice_text(
          row(%{status: "failed", reason: "exit_1"}),
          "Not logged in · Please run /login"
        )

      assert text =~ "check the working tree before redoing anything"
      assert text =~ "run it again if the cause looks transient"
      assert text =~ "carry out the work yourself with your ordinary file and shell tools"
      assert text =~ "tell the owner plainly what failed and what it needs"

      # The completed-run closing must not leak into a failure: "continue the
      # request" reads as "the work is done, wrap up", which is how a failed run
      # ends up silently reported as progress.
      refute text =~ "if it is already satisfied"
    end

    # The closing must never assert the worktree is untouched. `timeout`,
    # `output_limit` and `subscriber_stalled` kill a vendor that ran for minutes
    # inside the real repo, and `artifact_write` means it finished and only the
    # result file failed — claiming "nothing happened, redo it" would invite a
    # second implementation on top of a half-applied one.
    test "a failure that may have written files is told to inspect, not to assume" do
      for reason <- ["timeout", "output_limit", "subscriber_stalled", "artifact_write"] do
        text = Continuation.notice_text(row(%{status: "failed", reason: reason}), nil)

        assert text =~ "check the working tree before redoing anything"
        refute text =~ "produced no work"
      end
    end

    # A cloud terminal usually means tracking stopped, not that the task did —
    # `poll_deadline` leaves it running remotely, so the decision closing (which
    # sanctions redoing the work) must not appear or the agent races a live task.
    test "a cloud run never gets the do-it-yourself closing" do
      text =
        Continuation.notice_text(
          row(%{vendor: "codex_cloud", status: "blocked", reason: "poll_deadline"}),
          nil
        )

      refute text =~ "carry out the work yourself"
      assert text =~ "Continue the request this run was for"
    end

    test "a completed run keeps the continue-the-request closing" do
      text = Continuation.notice_text(row(), "All tests pass.")

      assert text =~ "Continue the request this run was for"
      refute text =~ "This run produced no work."
    end

    test "a completed cloud run carries the vendor summary, the task URL, and the diff hint" do
      text =
        Continuation.notice_text(
          row(%{
            vendor: "codex_cloud",
            cwd: "cloud:env-123",
            diagnostics_tail: "vendor status: completed · +12/-3 · 4 files",
            task_url: "https://chatgpt.com/codex/tasks/task_1",
            task_id: "task_1"
          }),
          nil
        )

      assert text =~ "codex_cloud · completed · cloud:env-123"
      assert text =~ "vendor status: completed · +12/-3 · 4 files"
      assert text =~ "https://chatgpt.com/codex/tasks/task_1"
      assert text =~ "Inspect the diff: codex cloud diff task_1"
    end

    test "an oversized result is truncated with a marker" do
      text = Continuation.notice_text(row(), String.duplicate("x", 20_000))

      assert text =~ "… [truncated]"
      assert byte_size(text) < 20_000
    end
  end

  describe "dispatch/4" do
    test "hands the dispatcher the frozen target, the notice text, and the next depth" do
      assert :ok = Continuation.dispatch(OkDispatcher, row(%{continuation_depth: 1}), "done")

      assert_receive {:dispatched, notice}, 1_000
      assert notice.platform == "telegram"
      assert notice.destination == "123"
      assert notice.thread == nil
      assert notice.content =~ "[coding run hr_000000000001 finished]"

      assert notice.metadata == %{
               harness_continuation: true,
               harness_run_id: "hr_000000000001",
               harness_continuation_depth: 2
             }
    end

    test "surfaces the dispatcher's refusal for the caller to record" do
      assert {:error, :nope} = Continuation.dispatch(FailingDispatcher, row(), nil)
    end

    test "refuses a row with no resolvable delivery target" do
      assert {:error, {:unresolvable_continuation_target, _}} =
               Continuation.dispatch(OkDispatcher, row(%{destination: nil}), nil)
    end

    # Cap behavior for a wedged re-ingest: the manager must not be blocked, and the
    # error keeps the row `pending` for the DeliveryWorker's text delivery.
    test "a dispatcher that wedges is bounded and reported as a failed dispatch" do
      assert {:error, :delivery_timeout} =
               Continuation.dispatch(WedgedDispatcher, row(), nil, timeout_ms: 50)
    end

    test "a dispatcher that crashes is reported as a failed dispatch, never as delivered" do
      assert {:error, {:delivery_crashed, _reason}} =
               Continuation.dispatch(CrashingDispatcher, row(), nil, timeout_ms: 1_000)
    end
  end

  describe "dispatcher/1" do
    test "prefers the injected seam over app env" do
      Application.put_env(:fermix_core, :harness_continuation_dispatcher, FailingDispatcher)
      assert {:ok, OkDispatcher} = Continuation.dispatcher(dispatcher: OkDispatcher)
    end

    test "reads the configured module when no seam is injected" do
      Application.put_env(:fermix_core, :harness_continuation_dispatcher, OkDispatcher)
      assert {:ok, OkDispatcher} = Continuation.dispatcher([])
    end

    test "is :none when nothing is configured (continuation off)" do
      Application.put_env(:fermix_core, :harness_continuation_dispatcher, nil)
      assert :none = Continuation.dispatcher([])
    end

    test "is :none for a module that cannot serve the behaviour" do
      Application.put_env(:fermix_core, :harness_continuation_dispatcher, NotADispatcher)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert :none = Continuation.dispatcher([])
             end) =~ "does not export dispatch/1"
    end
  end

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        id: "hr_000000000001",
        vendor: "codex",
        status: "completed",
        cwd: "/repo/apps/core",
        reason: nil,
        diagnostics_tail: nil,
        origin_kind: "chat",
        continuation_depth: 0,
        platform: "telegram",
        destination: "123",
        thread: nil
      },
      overrides
    )
  end
end
