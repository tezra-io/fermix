defmodule FermixCore.Harness.DeliveryTest do
  # async: false — the recording stub adapter routes through a named Agent, so
  # the module's tests must not run concurrently with each other.
  use ExUnit.Case, async: false

  alias FermixCore.Acp.Identity
  alias FermixCore.Harness.Continuation
  alias FermixCore.Harness.Delivery
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo

  @recorder :harness_delivery_recorder

  # Published NIP-19 test vector (see `nostr/key_test.exs`) — never a live key.
  @nsec "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"

  defp buzz_env do
    %{"BUZZ_PRIVATE_KEY" => @nsec, "PATH" => "/fake/bin:/usr/bin"}
  end

  defmodule RecordingAdapter do
    def send_message(destination, text, opts) do
      Agent.update(:harness_delivery_recorder, fn acc -> [{destination, text, opts} | acc] end)
      :ok
    end
  end

  defmodule FailingAdapter do
    def send_message(_destination, _text, _opts), do: {:error, :permanent}
  end

  setup do
    start_supervised!(%{
      id: @recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: @recorder]]}
    })

    :ok
  end

  defp recorded, do: Agent.get(@recorder, &Enum.reverse/1)

  defp completed_row(overrides \\ %{}) do
    Map.merge(
      %{
        id: "hr_000000000001",
        status: "completed",
        vendor: "codex",
        cwd: "/repo/apps/core",
        worktree_root: "/repo",
        resumable: true,
        vendor_session_id: "sess-1",
        reason: nil,
        diagnostics_tail: nil,
        delivery_mode: "origin",
        platform: "telegram",
        destination: "chat-1",
        thread: nil,
        send_opts: nil,
        started_at: ~U[2026-07-20 10:00:00Z],
        completed_at: ~U[2026-07-20 10:02:14Z],
        created_at: ~U[2026-07-20 10:00:00Z]
      },
      overrides
    )
  end

  defp cloud_row(overrides) do
    Map.merge(
      %{
        id: "hr_00000000cl01",
        status: "completed",
        vendor: "codex_cloud",
        cwd: "cloud:proj-web",
        worktree_root: "cloud:proj-web",
        resumable: false,
        reason: nil,
        diagnostics_tail: nil,
        task_id: "task_i_abc123",
        task_url: "https://chatgpt.com/codex/tasks/task_i_abc123",
        delivery_mode: "channel",
        platform: "telegram",
        destination: "chat-1",
        thread: nil,
        send_opts: nil,
        created_at: ~U[2026-07-20 10:00:00Z],
        completed_at: ~U[2026-07-20 10:02:14Z]
      },
      overrides
    )
  end

  describe "resolve_snapshot/2 — chat origin" do
    test "derives platform/destination and no thread for a root conversation" do
      ctx = %{conversation_key: {"telegram", "chat-9", :root}}

      assert {:ok, snapshot} = Delivery.resolve_snapshot(ctx)
      assert snapshot.origin_kind == "chat"
      assert snapshot.delivery_mode == "origin"
      assert snapshot.platform == "telegram"
      assert snapshot.destination == "chat-9"
      assert snapshot.thread == nil
      assert snapshot.parent_job_id == nil
    end

    test "carries the thread for a threaded conversation" do
      ctx = %{conversation_key: {"slack", "C123", "1699.55"}}

      assert {:ok, snapshot} = Delivery.resolve_snapshot(ctx)
      assert snapshot.platform == "slack"
      assert snapshot.destination == "C123"
      assert snapshot.thread == "1699.55"
    end

    test "treats a two-tuple key as a root conversation" do
      ctx = %{conversation_key: {"telegram", "chat-2"}}

      assert {:ok, snapshot} = Delivery.resolve_snapshot(ctx)
      assert snapshot.thread == nil
      assert snapshot.destination == "chat-2"
    end

    test "rejects an unresolvable origin" do
      assert {:error, {:unresolvable_delivery_origin, _}} =
               Delivery.resolve_snapshot(%{conversation_key: :nonsense})
    end

    # A framework-delivered channel has no `session_env`, so it must freeze no
    # client origin at all — the regression half of every assertion below.
    test "freezes no client origin for a framework-delivered channel" do
      ctx = %{conversation_key: {"telegram", "chat-9", :root}, cwd: "/repo"}

      assert {:ok, snapshot} = Delivery.resolve_snapshot(ctx)
      assert snapshot.client_origin == nil
    end
  end

  # M29 §17.4 — the ACP session that launched a run is gone by the time it
  # finishes, so the row freezes who it belonged to, where it ran, and an opaque
  # excerpt of the launching turn.
  describe "resolve_snapshot/2 — client-owned origin" do
    setup do
      unique = System.unique_integer([:positive])
      store = :"harness_delivery_convo_#{unique}"
      start_supervised!({ConversationStore, name: store})
      %{store: store}
    end

    test "freezes the identity, the launch cwd and an opaque reply excerpt", %{store: store} do
      key = {"acp", "sess-1", :root}

      ConversationStore.add_message(key, "user", "[Context] channel=abc\nfix the flake",
        server: store
      )

      ctx = %{
        conversation_key: key,
        cwd: "/repo/apps/core",
        session_env: buzz_env(),
        conversation_store: store
      }

      assert {:ok, snapshot} = Delivery.resolve_snapshot(ctx)
      assert snapshot.platform == "acp"

      # The SAME derivation the Peer used at hello, so launch and hello can never
      # disagree about who a run belongs to.
      assert {:ok, id} = Identity.id_from_env(buzz_env())
      assert snapshot.client_origin["identity"] == id
      assert snapshot.client_origin["cwd"] == "/repo/apps/core"
      assert snapshot.client_origin["reply_context"] == "[Context] channel=abc\nfix the flake"
    end

    test "bounds the reply excerpt and never stores invalid UTF-8", %{store: store} do
      key = {"acp", "sess-2", :root}
      long = String.duplicate("é", 8_000)
      ConversationStore.add_message(key, "user", long, server: store)

      ctx = %{conversation_key: key, session_env: buzz_env(), conversation_store: store}

      assert {:ok, snapshot} = Delivery.resolve_snapshot(ctx)
      excerpt = snapshot.client_origin["reply_context"]

      assert byte_size(excerpt) <= 4_096
      assert String.valid?(excerpt)
      # It has to survive the ledger encode, which is where invalid UTF-8 would raise.
      assert is_binary(Jason.encode!(snapshot.client_origin))
    end

    # A two-element key is normalized to a root conversation on BOTH the snapshot
    # and the excerpt read, so the store is never addressed with a key shape it
    # cannot resolve.
    test "reads the excerpt through the normalized root key for a two-element key", %{
      store: store
    } do
      ConversationStore.add_message({"acp", "sess-4", :root}, "user", "fix the flake",
        server: store
      )

      ctx = %{
        conversation_key: {"acp", "sess-4"},
        session_env: buzz_env(),
        conversation_store: store
      }

      assert {:ok, snapshot} = Delivery.resolve_snapshot(ctx)
      assert snapshot.client_origin["reply_context"] == "fix the flake"
    end

    # The drop rule (§17.2): a key that will not derive is not an identity, so the
    # row must freeze no client origin rather than one nothing can resolve.
    test "an underivable signing key freezes no client origin", %{store: store} do
      key = {"acp", "sess-3", :root}
      ConversationStore.add_message(key, "user", "do the work", server: store)

      ctx = %{
        conversation_key: key,
        session_env: %{"BUZZ_PRIVATE_KEY" => "nsec1thisisnotarealkey", "PATH" => "/bin"},
        conversation_store: store
      }

      assert {:ok, snapshot} = Delivery.resolve_snapshot(ctx)
      assert snapshot.client_origin == nil
    end
  end

  describe "resolve_snapshot/2 — scheduled origin" do
    setup do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-harness-delivery-#{unique}.db")
      repo = :"harness_delivery_repo_#{unique}"

      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
          FermixTestSupport.SafeRm.rm(path)
        end)
      end)

      {:ok, job} =
        JobsRegistry.create_job(
          %{
            created_by_trust: "operator",
            name: "Nightly Refactor",
            description: "Refactor the delivery seam.",
            schedule: "every 15 minutes",
            timezone: "UTC",
            task_prompt: "Refactor.",
            created_by_agent_id: "main",
            created_by_session_id: "telegram:chat-1:root",
            allowed_tools: ["codex_run"],
            capability_policy: ["exec"],
            delivery_mode: "channel",
            delivery_target: %{"platform" => "telegram", "chat_id" => "999", "thread_ts" => "42"}
          },
          repo: repo,
          now: ~U[2026-07-20 14:00:00Z]
        )

      %{repo: repo, job: job}
    end

    test "copies the parent job's frozen delivery target", %{repo: repo, job: job} do
      ctx = %{conversation_key: {:scheduled_job, job.id, "run-1"}, memory_repo: repo}

      assert {:ok, snapshot} = Delivery.resolve_snapshot(ctx)
      assert snapshot.origin_kind == "scheduled"
      assert snapshot.delivery_mode == "channel"
      assert snapshot.platform == "telegram"
      assert snapshot.destination == "999"
      assert snapshot.thread == "42"
      assert snapshot.parent_job_id == job.id
    end

    test "reports a lookup failure for a missing parent job", %{repo: repo} do
      ctx = %{conversation_key: {:scheduled_job, "job:absent", "run-1"}, memory_repo: repo}

      assert {:error, {:parent_job_lookup_failed, _}} = Delivery.resolve_snapshot(ctx)
    end
  end

  describe "compose/2" do
    test "a completed run leads with the run tag and appends the bounded result" do
      message = Delivery.compose(completed_row(), "All tests pass.")

      assert message ==
               "[run hr_000000000001] completed — codex · …/apps/core · 2m14s\nAll tests pass."
    end

    test "a failed run carries reason, diagnostics tail, and a resume hint" do
      row =
        completed_row(%{
          id: "hr_000000000002",
          status: "failed",
          cwd: "/repo",
          reason: "exit_1",
          diagnostics_tail: "error: boom\nstack frame",
          vendor_session_id: "sess-2"
        })

      message = Delivery.compose(row, nil)

      assert message =~ "[run hr_000000000002] failed — codex · repo · 2m14s"
      assert message =~ "reason: exit_1"
      assert message =~ "error: boom\nstack frame"
      assert message =~ "Resume: cd /repo && codex exec resume sess-2 --json"
    end

    # Regression: "reason: exit_1" tells the owner nothing. When the vendor
    # explained itself on its terminal event, that text is the whole diagnosis and
    # must reach the delivered message.
    test "a failed run leads with the vendor's own error text when it has one" do
      row =
        completed_row(%{
          id: "hr_000000000009",
          status: "failed",
          cwd: "/repo",
          reason: "exit_1",
          diagnostics_tail: nil
        })

      message = Delivery.compose(row, "Not logged in · Please run /login")

      assert message =~ "Not logged in · Please run /login"
      assert message =~ "reason: exit_1"

      # Position, not just presence: reordering failed_body/2 would keep bare
      # presence assertions green while the message opened with "reason: exit_1"
      # again — the exact uninformative lead this change removed.
      vendor_at = :binary.match(message, "Not logged in") |> elem(0)
      reason_at = :binary.match(message, "reason: exit_1") |> elem(0)
      assert vendor_at < reason_at
    end

    test "an interrupted run offers the resume hint" do
      row =
        completed_row(%{
          id: "hr_000000000003",
          status: "interrupted",
          reason: nil,
          diagnostics_tail: nil,
          started_at: nil,
          completed_at: nil
        })

      message = Delivery.compose(row, nil)

      assert message =~ "[run hr_000000000003] interrupted — codex · …/apps/core"
      assert message =~ "Resume: cd /repo/apps/core && codex exec resume sess-1 --json"
    end

    test "a non-resumable run states so instead of a resume hint" do
      row =
        completed_row(%{
          id: "hr_000000000004",
          status: "failed",
          resumable: false,
          reason: "exit_2"
        })

      message = Delivery.compose(row, nil)

      assert message =~ "reason: exit_2"
      assert message =~ "Not resumable (ephemeral)."
      refute message =~ "Resume:"
    end

    test "truncates an oversized completed result with a marker" do
      big = String.duplicate("x", 20_000)
      message = Delivery.compose(completed_row(), big)

      assert message =~ "… [truncated]"
      assert byte_size(message) < byte_size(big)
    end

    # Design §23.2: at the chain cap the outcome is delivered as text WITH an
    # explicit note that automatic follow-up stopped — a defined cap behavior.
    test "a depth-capped chat-origin run says automatic follow-up stopped" do
      row = completed_row(%{origin_kind: "chat", continuation_depth: Continuation.max_depth()})
      message = Delivery.compose(row, "All tests pass.")

      assert message =~ "All tests pass."
      assert message =~ "Automatic follow-up stopped here"
    end

    test "a run inside the cap and a scheduled origin carry no cap note" do
      inside = completed_row(%{origin_kind: "chat", continuation_depth: 1})
      scheduled = completed_row(%{origin_kind: "scheduled", continuation_depth: 9})

      refute Delivery.compose(inside, "ok") =~ "Automatic follow-up stopped"
      refute Delivery.compose(scheduled, "ok") =~ "Automatic follow-up stopped"
    end
  end

  describe "compose/2 — cloud rows" do
    test "a completed cloud run leads with vendor status + diff line, the URL, and a diff hint" do
      row = cloud_row(%{diagnostics_tail: "vendor status: ready · +42/-8 · 3 files"})

      message = Delivery.compose(row, nil)

      assert message ==
               "[run hr_00000000cl01] completed — codex_cloud · cloud:proj-web · 2m14s\n" <>
                 "vendor status: ready · +42/-8 · 3 files\n" <>
                 "https://chatgpt.com/codex/tasks/task_i_abc123\n" <>
                 "Inspect the diff: codex cloud diff task_i_abc123"

      # A cloud run is never resumable, but its body carries no resume/ephemeral
      # line and no result.txt body — only the vendor status, URL, and diff hint.
      refute message =~ "Resume:"
      refute message =~ "Not resumable"
    end

    test "a blocked/tracking_stopped run carries the URL and never claims the vendor task stopped" do
      row =
        cloud_row(%{
          status: "blocked",
          reason: "tracking_stopped",
          diagnostics_tail:
            "Stopped tracking this cloud task. The vendor task itself keeps running — check it on ChatGPT."
        })

      message = Delivery.compose(row, nil)

      assert message =~ "[run hr_00000000cl01] blocked — codex_cloud · cloud:proj-web · 2m14s"
      assert message =~ "reason: tracking_stopped"
      assert message =~ "keeps running"
      assert message =~ "https://chatgpt.com/codex/tasks/task_i_abc123"
      assert message =~ "codex cloud diff task_i_abc123"
      refute message =~ "Resume:"
    end

    test "a blocked/poll_deadline run delivers the task URL" do
      row =
        cloud_row(%{
          status: "blocked",
          reason: "poll_deadline",
          diagnostics_tail: "Polling deadline reached with no terminal vendor status."
        })

      message = Delivery.compose(row, nil)

      assert message =~ "reason: poll_deadline"
      assert message =~ "https://chatgpt.com/codex/tasks/task_i_abc123"
      assert message =~ "codex cloud diff task_i_abc123"
    end

    test "a submission-unknown run WITHOUT a task id carries no URL or diff hint" do
      row =
        cloud_row(%{
          status: "blocked",
          reason: "submission_outcome_unknown",
          diagnostics_tail:
            "Submission outcome unknown — the daemon restarted mid-submit. " <>
              "Inspect `codex cloud list` to see whether a task was created.",
          task_id: nil,
          task_url: nil
        })

      message = Delivery.compose(row, nil)

      assert message =~ "reason: submission_outcome_unknown"
      assert message =~ "codex cloud list"
      refute message =~ "https://chatgpt.com/codex/tasks"
      refute message =~ "codex cloud diff"
    end

    test "a submission-unknown run WITH a known task (poll schedule lost) still points at the URL" do
      row =
        cloud_row(%{
          status: "blocked",
          reason: "submission_outcome_unknown",
          diagnostics_tail:
            "The Codex cloud task was created but its poll schedule could not be persisted, " <>
              "so tracking stopped. The task keeps running — inspect `codex cloud list`."
        })

      message = Delivery.compose(row, nil)

      assert message =~ "reason: submission_outcome_unknown"
      assert message =~ "https://chatgpt.com/codex/tasks/task_i_abc123"
      assert message =~ "codex cloud diff task_i_abc123"
    end
  end

  describe "deliver/2" do
    test "origin mode composes and makes one send attempt" do
      row = completed_row(%{status: "failed", reason: "exit_1", thread: "77"})

      assert {:ok, :sent} = Delivery.deliver(row, adapter: RecordingAdapter)

      assert [{"chat-1", text, opts}] = recorded()
      assert text =~ "[run hr_000000000001] failed"
      assert Keyword.get(opts, :thread_ts) == "77"
      assert Keyword.get(opts, :message_thread_id) == "77"
    end

    test "none mode skips without a send" do
      row = completed_row(%{delivery_mode: "none"})

      assert {:ok, :skipped} = Delivery.deliver(row, adapter: RecordingAdapter)
      assert recorded() == []
    end

    test "local mode is sent without a channel send" do
      row = completed_row(%{delivery_mode: "local"})

      assert {:ok, :sent} = Delivery.deliver(row, adapter: RecordingAdapter)
      assert recorded() == []
    end

    test "surfaces a send failure for the caller to record" do
      row = completed_row(%{status: "failed", reason: "exit_1"})

      assert {:error, :permanent} =
               Delivery.deliver(row, adapter: FailingAdapter, delivery_backoff_ms: 0)
    end

    test "reads a completed run's result artifact from disk" do
      dir = tmp_run_dir()
      File.write!(Path.join(dir, "result.txt"), "Persisted result body.")

      row = completed_row(%{artifacts_dir: dir})

      assert {:ok, :sent} = Delivery.deliver(row, adapter: RecordingAdapter)
      assert [{"chat-1", text, _opts}] = recorded()
      assert text =~ "Persisted result body."
    end

    # A retry long after terminalization sees only the ledger row, so the vendor's
    # error has to survive on disk. `Harness.Run` persists it for failed runs for
    # exactly this reader — before, `result_text_for/1` matched `"completed"` only
    # and the diagnosis was lost on every retried failure.
    test "reads a failed run's persisted vendor error from disk" do
      dir = tmp_run_dir()
      File.write!(Path.join(dir, "result.txt"), "Not logged in · Please run /login")

      row = completed_row(%{status: "failed", reason: "exit_1", artifacts_dir: dir})

      assert {:ok, :sent} = Delivery.deliver(row, adapter: RecordingAdapter)
      assert [{"chat-1", text, _opts}] = recorded()
      assert text =~ "Not logged in · Please run /login"
    end
  end

  describe "notice/3" do
    test "sends best-effort advisory text for a channel row" do
      row = completed_row()

      assert :ok = Delivery.notice(row, "still working…", adapter: RecordingAdapter)
      assert [{"chat-1", "still working…", _opts}] = recorded()
    end

    test "is a no-op for a none-mode row" do
      row = completed_row(%{delivery_mode: "none"})

      assert :ok = Delivery.notice(row, "still working…", adapter: RecordingAdapter)
      assert recorded() == []
    end

    test "swallows a send failure and returns :ok" do
      row = completed_row()

      assert :ok = Delivery.notice(row, "still working…", adapter: FailingAdapter)
      assert recorded() == []
    end
  end

  defp tmp_run_dir do
    dir =
      Path.join([
        System.tmp_dir!(),
        "fermix-harness-delivery-artifacts",
        "run-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    dir
  end
end
