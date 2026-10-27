defmodule FermixCore.Memory.RepoCueRunsTest do
  @moduledoc """
  The cue-run half of M60 §9.2 and §9.4 at the Repo: admission candidates, the
  claim of one passed delivery with its run, and the settle that moves the
  delivery with the run in one transaction.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import FermixTestSupport.CueFixtures

  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesRunsSql
  alias FermixCore.Memory.Repo.CuesSql

  @now ~U[2026-10-10 12:00:00Z]

  setup do
    start_repo("cue_runs")
  end

  # --- fixtures ----------------------------------------------------------------

  # A watcher on `sources` with its cue-only job; `daily_cap` as given.
  defp watcher(conn, sources, opts \\ []) do
    id = insert_watcher(conn, %{filter: "none", sources: sources})

    exec!(conn, "UPDATE cue_watchers SET daily_cap = ? WHERE id = ?", [
      Keyword.get(opts, :daily_cap, 0),
      id
    ])

    [[job_id]] = rows(conn, "SELECT task_job_id FROM cue_watchers WHERE id = ?", [id])

    exec!(
      conn,
      "UPDATE scheduled_jobs SET schedule_kind = 'cue', schedule_expr = 'cue', " <>
        "next_run_at = NULL, timezone = 'UTC' WHERE id = ?",
      [job_id]
    )

    %{id: id, job_id: job_id}
  end

  # One cue and its delivery to `watcher`, inserted in arrival order, so the
  # delivery id is the arrival order. Returns the delivery id.
  defp delivery(conn, watcher, attrs) do
    unique = System.unique_integer([:positive])
    source = Map.fetch!(attrs, :source)
    received = Map.get(attrs, :received_at, ~U[2026-10-10 11:00:00Z])

    [[cue_id]] =
      rows(
        conn,
        """
        INSERT INTO cues (source_ref, item_id, type, subject, received_at, content_hash,
          payload, payload_bytes, routed_count, last_seen_at)
        VALUES (?, ?, 't', ?, ?, ?, '{}', 2, 1, ?) RETURNING id
        """,
        [
          source,
          "item-#{unique}",
          attrs[:subject],
          stamp(received),
          "h#{unique}",
          stamp(received)
        ]
      )

    [[delivery_id]] =
      rows(
        conn,
        """
        INSERT INTO cue_deliveries (cue_id, watcher_id, source_ref, subject, received_at, state,
          task_attempts, ready_at, valid_until)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id
        """,
        [
          cue_id,
          watcher.id,
          source,
          attrs[:subject],
          stamp(received),
          Map.get(attrs, :state, "passed"),
          Map.get(attrs, :task_attempts, 0),
          stamp(Map.get(attrs, :ready_at, received)),
          stamp(DateTime.add(received, 7 * 86_400, :second))
        ]
      )

    delivery_id
  end

  # A finished cue run of `watcher`'s job created at `at`, holding `delivery_id`.
  defp past_cue_run(conn, watcher, delivery_id, at) do
    exec!(
      conn,
      """
      INSERT INTO job_runs (id, job_id, session_id, trigger, status, created_at, updated_at,
        cue_delivery_id)
      VALUES (?, ?, ?, 'cue', 'ok', ?, ?, ?)
      """,
      [
        "run_past_#{System.unique_integer([:positive])}",
        watcher.job_id,
        "cron_past",
        DateTime.to_iso8601(at),
        DateTime.to_iso8601(at),
        delivery_id
      ]
    )
  end

  defp stamp(at), do: CuesSql.stamp(at)

  defp run_attrs(watcher, now) do
    %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: watcher.job_id,
      session_id: "cron_#{watcher.job_id}_test_#{System.unique_integer([:positive])}",
      trigger: "cue",
      status: "queued",
      claimed_at: now,
      delivery_status: "none",
      created_at: now,
      updated_at: now
    }
  end

  defp candidates(repo, now, limit \\ 4) do
    {:ok, %{candidates: rows}} =
      Repo.cues_call(CuesRunsSql, {:admission_candidates, now, limit}, server: repo)

    rows
  end

  defp capped(repo, now) do
    {:ok, %{capped: rows}} =
      Repo.cues_call(CuesRunsSql, {:admission_candidates, now, 4}, server: repo)

    rows
  end

  defp claim!(repo, watcher, now) do
    {:ok, claim} = Repo.claim_cue_run(watcher.job_id, run_attrs(watcher, now), now, server: repo)
    claim
  end

  defp finish(run, status, at) do
    Map.merge(run, %{status: status, completed_at: at, updated_at: at})
  end

  defp delivery_row(conn, id) do
    [[state, outcome, attempts, ready_at, claimed_run_id, settled_at]] =
      rows(
        conn,
        "SELECT state, outcome, task_attempts, ready_at, claimed_run_id, settled_at " <>
          "FROM cue_deliveries WHERE id = ?",
        [id]
      )

    %{
      state: state,
      outcome: outcome,
      task_attempts: attempts,
      ready_at: ready_at,
      claimed_run_id: claimed_run_id,
      settled_at: settled_at
    }
  end

  defp job_row(conn, job_id) do
    [[state, last_run_at, last_status, last_error]] =
      rows(
        conn,
        "SELECT state, last_run_at, last_status, last_error FROM scheduled_jobs WHERE id = ?",
        [job_id]
      )

    %{state: state, last_run_at: last_run_at, last_status: last_status, last_error: last_error}
  end

  # --- the claim ---------------------------------------------------------------

  describe "claim_cue_run/4" do
    test "claims the oldest passed delivery with its run in one transaction", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      first = delivery(conn, w, %{source: "src-a"})
      _second = delivery(conn, w, %{source: "src-a"})

      assert %{job: job, run: run, delivery: claimed} = claim!(repo, w, @now)

      assert job.state == "running"
      assert run.trigger == "cue"
      assert run.cue_delivery_id == first
      assert run.status == "queued"
      assert claimed.id == first
      assert claimed.watcher_id == w.id
      assert claimed.source_ref == "src-a"
      assert claimed.state == "claimed"

      assert %{state: "claimed", claimed_run_id: run_id} = delivery_row(conn, first)
      assert run_id == run.id
    end

    test "a job with no eligible delivery is nothing due, and nothing is written", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      _later = delivery(conn, w, %{source: "src-a", ready_at: DateTime.add(@now, 60, :second)})

      assert {:error, :nothing_due} =
               Repo.claim_cue_run(w.job_id, run_attrs(w, @now), @now, server: repo)

      assert [[0]] = rows(conn, "SELECT COUNT(*) FROM job_runs")
      assert job_row(conn, w.job_id).state == "scheduled"
    end

    test "a delivery moved by someone else after the candidate read is nothing due", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      id = delivery(conn, w, %{source: "src-a"})
      assert [%{job_id: job_id, delivery_id: ^id}] = candidates(repo, @now)

      # The retention sweep or a watcher removal lands between the read and the claim.
      exec!(
        conn,
        "UPDATE cue_deliveries SET state = 'expired', outcome = 'lifetime', settled_at = ? " <>
          "WHERE id = ?",
        [stamp(@now), id]
      )

      assert {:error, :nothing_due} =
               Repo.claim_cue_run(job_id, run_attrs(w, @now), @now, server: repo)

      assert [[0]] = rows(conn, "SELECT COUNT(*) FROM job_runs")
      assert job_row(conn, w.job_id).state == "scheduled"
      assert delivery_row(conn, id).state == "expired"
    end

    # Design §7.4: an item past its lifetime expires; a daemon that was off
    # for longer finds it still `passed`, and the scheduler may ask before the
    # retention sweep runs. The claim must not run it.
    test "a delivery past its lifetime is never claimed, even before retention runs", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      stale = delivery(conn, w, %{source: "src-a", received_at: ~U[2026-10-01 11:00:00Z]})
      live = delivery(conn, w, %{source: "src-a", received_at: ~U[2026-10-07 11:00:00Z]})
      at = ~U[2026-10-08 12:00:00Z]

      assert [%{delivery_id: ^live}] = candidates(repo, at)
      assert %{delivery: %{id: ^live}} = claim!(repo, w, at)
      assert delivery_row(conn, stale).state == "passed"
    end

    test "a paused job is never claimed", ctx do
      %{repo: repo, conn: conn} = ctx
      paused = watcher(conn, ["src-a"])
      _p = delivery(conn, paused, %{source: "src-a"})

      exec!(conn, "UPDATE scheduled_jobs SET enabled = 0, state = 'paused' WHERE id = ?", [
        paused.job_id
      ])

      assert candidates(repo, @now) == []

      assert {:error, :nothing_due} =
               Repo.claim_cue_run(paused.job_id, run_attrs(paused, @now), @now, server: repo)
    end

    # Design §8.8: pausing a watcher stops routing and filtering; the items it
    # already passed still wake its task.
    test "a paused watcher's passed delivery still wakes its task", ctx do
      %{repo: repo, conn: conn} = ctx
      off = watcher(conn, ["src-b"])
      held = delivery(conn, off, %{source: "src-b"})

      exec!(conn, "UPDATE cue_watchers SET enabled = 0 WHERE id = ?", [off.id])

      assert [%{job_id: job_id, delivery_id: ^held}] = candidates(repo, @now)
      assert job_id == off.job_id

      assert {:ok, %{delivery: %{id: ^held, state: "claimed"}}} =
               Repo.claim_cue_run(off.job_id, run_attrs(off, @now), @now, server: repo)
    end

    test "a job's earlier run still active holds its next cue", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      _first = delivery(conn, w, %{source: "src-a"})
      _second = delivery(conn, w, %{source: "src-a"})
      _claim = claim!(repo, w, @now)

      # A resume put the job back to scheduled while its run is still active.
      exec!(conn, "UPDATE scheduled_jobs SET state = 'scheduled' WHERE id = ?", [w.job_id])

      assert candidates(repo, @now) == []

      assert {:error, :nothing_due} =
               Repo.claim_cue_run(w.job_id, run_attrs(w, @now), @now, server: repo)
    end
  end

  # --- candidates ----------------------------------------------------------------

  describe "admission candidates" do
    test "one row per task, ordered by its oldest eligible delivery (cross-task fairness)",
         ctx do
      %{repo: repo, conn: conn} = ctx
      a = watcher(conn, ["src-a"])
      b = watcher(conn, ["src-b"])

      b1 = delivery(conn, b, %{source: "src-b"})
      a1 = delivery(conn, a, %{source: "src-a"})
      _a2 = delivery(conn, a, %{source: "src-a"})
      _b2 = delivery(conn, b, %{source: "src-b"})

      assert [
               %{job_id: bj, watcher_id: bw, delivery_id: ^b1},
               %{job_id: aj, watcher_id: aw, delivery_id: ^a1}
             ] = candidates(repo, @now)

      assert {bj, bw, aj, aw} == {b.job_id, b.id, a.job_id, a.id}
      assert [%{delivery_id: ^b1}] = candidates(repo, @now, 1)
    end

    test "a delivery whose ready time is later waits", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      id = delivery(conn, w, %{source: "src-a", ready_at: DateTime.add(@now, 30, :second)})

      assert candidates(repo, @now) == []
      assert [%{delivery_id: ^id}] = candidates(repo, DateTime.add(@now, 30, :second))
    end
  end

  # --- C53: the subject rule ------------------------------------------------------

  describe "subject order (C53)" do
    test "a retried cue holds its subject; a cue with no subject runs without waiting", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      failing = delivery(conn, w, %{source: "src-a", subject: "disk-1"})
      plain = delivery(conn, w, %{source: "src-a"})
      answer = delivery(conn, w, %{source: "src-a", subject: "disk-1"})

      %{run: run} = claim!(repo, w, @now)
      assert run.cue_delivery_id == failing

      {:ok, {_run, _job, %{disposition: :retry}}} =
        Repo.settle_cue_run(finish(run, "error", @now), {:failed, :other}, server: repo)

      # The first failed once: the cue with no subject goes next, the answer waits.
      assert [%{delivery_id: ^plain}] = candidates(repo, @now)
      %{run: plain_run} = claim!(repo, w, @now)
      assert plain_run.cue_delivery_id == plain

      {:ok, _settled} =
        Repo.settle_cue_run(finish(plain_run, "ok", @now), :ignored, server: repo)

      later = DateTime.add(@now, 31, :second)
      assert [%{delivery_id: ^failing}] = candidates(repo, later)
      %{run: retry_run} = claim!(repo, w, later)

      {:ok, _settled} =
        Repo.settle_cue_run(finish(retry_run, "ok", later), :acted, server: repo)

      assert [%{delivery_id: ^answer}] = candidates(repo, later)
    end

    test "an older cue of the subject still pending or filtering blocks a later passed one",
         ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])

      for state <- ["pending", "filtering"] do
        older = delivery(conn, w, %{source: "src-a", subject: "subj-#{state}", state: state})
        _newer = delivery(conn, w, %{source: "src-a", subject: "subj-#{state}"})

        assert candidates(repo, @now) == []

        exec!(
          conn,
          "UPDATE cue_deliveries SET state = 'dropped', settled_at = ? WHERE id = ?",
          [stamp(@now), older]
        )

        assert [%{watcher_id: watcher_id}] = candidates(repo, @now)
        assert watcher_id == w.id

        exec!(conn, "UPDATE cue_deliveries SET state = 'dropped', settled_at = ? WHERE id > ?", [
          stamp(@now),
          older
        ])
      end
    end
  end

  # --- C25: the daily cap ---------------------------------------------------------

  describe "daily cap (C25)" do
    test "a reached cap holds the next cue; runs older than 24 hours do not count", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"], daily_cap: 48)
      old = delivery(conn, w, %{source: "src-a", state: "acked"})

      for n <- 1..47, do: past_cue_run(conn, w, old, DateTime.add(@now, -n * 60, :second))
      past_cue_run(conn, w, old, DateTime.add(@now, -25 * 3600, :second))
      waiting = delivery(conn, w, %{source: "src-a"})

      assert [%{delivery_id: ^waiting}] = candidates(repo, @now)

      past_cue_run(conn, w, old, DateTime.add(@now, -10, :second))
      assert candidates(repo, @now) == []

      assert {:error, :nothing_due} =
               Repo.claim_cue_run(w.job_id, run_attrs(w, @now), @now, server: repo)
    end

    test "one of two sources stops at half the cap while the other still runs", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a", "src-b"], daily_cap: 48)
      flood = delivery(conn, w, %{source: "src-a", state: "acked"})

      for n <- 1..24, do: past_cue_run(conn, w, flood, DateTime.add(@now, -n * 60, :second))
      _held = delivery(conn, w, %{source: "src-a"})
      story = delivery(conn, w, %{source: "src-b"})

      assert [%{delivery_id: ^story}] = candidates(repo, @now)
      assert %{delivery: %{id: ^story}} = claim!(repo, w, @now)
    end

    test "a single-source watcher may use its whole cap", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"], daily_cap: 48)
      flood = delivery(conn, w, %{source: "src-a", state: "acked"})

      for n <- 1..30, do: past_cue_run(conn, w, flood, DateTime.add(@now, -n * 60, :second))
      next = delivery(conn, w, %{source: "src-a"})

      assert [%{delivery_id: ^next}] = candidates(repo, @now)
    end

    test "a watcher whose oldest waiting cue only the cap holds is reported capped", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"], daily_cap: 2)
      done = delivery(conn, w, %{source: "src-a", state: "acked"})
      _first = delivery(conn, w, %{source: "src-a"})
      _second = delivery(conn, w, %{source: "src-a"})

      past_cue_run(conn, w, done, DateTime.add(@now, -60, :second))
      assert capped(repo, @now) == []

      past_cue_run(conn, w, done, DateTime.add(@now, -30, :second))
      assert candidates(repo, @now) == []
      assert [%{watcher_id: watcher_id, daily_cap: 2, waiting: 2}] = capped(repo, @now)
      assert watcher_id == w.id
    end

    test "the half cap of one source is reported; a cue held by something else is not", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a", "src-b"], daily_cap: 4)
      flood = delivery(conn, w, %{source: "src-a", state: "acked"})
      for n <- 1..2, do: past_cue_run(conn, w, flood, DateTime.add(@now, -n * 60, :second))
      _held = delivery(conn, w, %{source: "src-a"})

      assert [%{watcher_id: watcher_id, daily_cap: 4, waiting: 1}] = capped(repo, @now)
      assert watcher_id == w.id

      # A later ready time holds it too: that is not the cap's doing.
      exec!(conn, "UPDATE cue_deliveries SET ready_at = ? WHERE state = 'passed'", [
        stamp(DateTime.add(@now, 30, :second))
      ])

      assert capped(repo, @now) == []
    end

    test "a cap of 0 lets every passed cue run", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a", "src-b"], daily_cap: 0)
      flood = delivery(conn, w, %{source: "src-a", state: "acked"})

      for n <- 1..60, do: past_cue_run(conn, w, flood, DateTime.add(@now, -n * 60, :second))
      next = delivery(conn, w, %{source: "src-a"})

      assert [%{delivery_id: ^next}] = candidates(repo, @now)
    end
  end

  # --- the settle (§9.4) ------------------------------------------------------------

  describe "settle_cue_run/3" do
    test "ignored and acted ack the delivery and leave the job's last run fields alone", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])

      for {outcome, label} <- [ignored: "ignored", acted: "acted"] do
        id = delivery(conn, w, %{source: "src-a"})
        %{run: run} = claim!(repo, w, @now)

        assert {:ok, {settled, job, settlement}} =
                 Repo.settle_cue_run(finish(run, "ok", @now), outcome, server: repo)

        assert settled.status == "ok"
        assert job.state == "scheduled"
        assert job.last_run_at == nil
        assert job.last_status == nil
        assert job.last_error == nil

        assert settlement.disposition == :acked
        assert settlement.delivery_id == id
        assert settlement.outcome == label

        assert %{state: "acked", outcome: ^label, settled_at: settled_at} =
                 delivery_row(conn, id)

        assert is_binary(settled_at)
      end
    end

    test "a cue run's error never reaches the job row", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      _id = delivery(conn, w, %{source: "src-a"})
      %{run: run} = claim!(repo, w, @now)

      attrs = run |> finish("error", @now) |> Map.put(:error, "loop killed: repeated call")
      {:ok, _settled} = Repo.settle_cue_run(attrs, {:failed, :other}, server: repo)

      assert %{state: "scheduled", last_run_at: nil, last_status: nil, last_error: nil} =
               job_row(conn, w.job_id)
    end

    test "provider failures retry after 30 s, 2 min, then every 10 min without an attempt",
         ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      id = delivery(conn, w, %{source: "src-a"})

      delays =
        Enum.map_reduce(1..4, @now, fn _n, at ->
          %{run: run} = claim!(repo, w, at)

          {:ok, {_run, _job, settlement}} =
            Repo.settle_cue_run(finish(run, "error", at), {:failed, :provider}, server: repo)

          assert settlement.disposition == :retry
          assert settlement.task_attempts == 0
          {DateTime.diff(settlement.ready_at, at, :second), settlement.ready_at}
        end)
        |> elem(0)

      assert delays == [30, 120, 600, 600]

      assert %{state: "passed", task_attempts: 0, claimed_run_id: nil, settled_at: nil} =
               delivery_row(conn, id)
    end

    test "other failures spend an attempt; the third ends it exhausted", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      id = delivery(conn, w, %{source: "src-a"})

      %{run: first} = claim!(repo, w, @now)

      {:ok, {_run, _job, one}} =
        Repo.settle_cue_run(finish(first, "timeout", @now), {:failed, :other}, server: repo)

      assert {one.disposition, one.task_attempts} == {:retry, 1}
      assert DateTime.diff(one.ready_at, @now, :second) == 30

      at = one.ready_at
      %{run: second} = claim!(repo, w, at)

      {:ok, {_run, _job, two}} =
        Repo.settle_cue_run(finish(second, "error", at), {:failed, :other}, server: repo)

      assert {two.disposition, two.task_attempts} == {:retry, 2}
      assert DateTime.diff(two.ready_at, at, :second) == 120

      at = two.ready_at
      %{run: third} = claim!(repo, w, at)

      {:ok, {_run, _job, three}} =
        Repo.settle_cue_run(finish(third, "error", at), {:failed, :other}, server: repo)

      assert three.disposition == :exhausted
      assert three.outcome == "task_failed"

      assert %{state: "exhausted", outcome: "task_failed", task_attempts: 3} =
               delivery_row(conn, id)

      assert candidates(repo, DateTime.add(at, 3600, :second)) == []
    end

    test "any failure after an allowed mandate call or a proposal is exhausted (C12)", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])

      for settle_by <- [{:failed, :provider}, {:failed, :other}, :scheduler] do
        id = delivery(conn, w, %{source: "src-a"})
        %{run: run} = claim!(repo, w, @now)

        # Lane F's marker, written in its own Repo call while the run is active.
        exec!(conn, "UPDATE job_runs SET tools_started_at = ?, started_at = ? WHERE id = ?", [
          DateTime.to_iso8601(@now),
          DateTime.to_iso8601(@now),
          run.id
        ])

        {:ok, {settled, _job, settlement}} =
          Repo.settle_cue_run(finish(run, "error", @now), settle_by, server: repo)

        assert settlement.disposition == :exhausted
        assert settlement.outcome == "failed_after_action"
        # The runner's copy of the row never clears the marker.
        assert settled.tools_started_at == @now
        assert %{state: "exhausted", outcome: "failed_after_action"} = delivery_row(conn, id)
      end
    end

    test "a run whose mandate calls were all refused, then timed out, is retried (C12)", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      id = delivery(conn, w, %{source: "src-a"})
      %{run: run} = claim!(repo, w, @now)

      {:ok, {_run, _job, settlement}} =
        Repo.settle_cue_run(finish(run, "timeout", @now), {:failed, :other}, server: repo)

      assert {settlement.disposition, settlement.task_attempts} == {:retry, 1}
      assert %{state: "passed", task_attempts: 1} = delivery_row(conn, id)
    end

    test "the scheduler's settle reads the run row: never started", ctx do
      %{repo: repo, conn: conn} = ctx
      capped = watcher(conn, ["src-a"], daily_cap: 10)
      uncapped = watcher(conn, ["src-b"])
      capped_id = delivery(conn, capped, %{source: "src-a"})
      uncapped_id = delivery(conn, uncapped, %{source: "src-b"})

      %{run: capped_run} = claim!(repo, capped, @now)
      %{run: uncapped_run} = claim!(repo, uncapped, @now)

      {:ok, {_run, _job, held}} =
        Repo.settle_cue_run(finish(capped_run, "error", @now), :scheduler, server: repo)

      {:ok, {_run, _job, spent}} =
        Repo.settle_cue_run(finish(uncapped_run, "error", @now), :scheduler, server: repo)

      assert {held.disposition, held.task_attempts} == {:retry, 0}
      assert %{state: "passed", task_attempts: 0} = delivery_row(conn, capped_id)
      assert {spent.disposition, spent.task_attempts} == {:retry, 1}
      assert %{state: "passed", task_attempts: 1} = delivery_row(conn, uncapped_id)
    end

    test "the scheduler's settle of a started run spends an attempt", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"], daily_cap: 10)
      id = delivery(conn, w, %{source: "src-a", task_attempts: 2})
      %{run: run} = claim!(repo, w, @now)

      {:ok, running} =
        Repo.upsert_job_run(%{run | status: "running", started_at: @now}, server: repo)

      {:ok, {_run, _job, settlement}} =
        Repo.settle_cue_run(finish(running, "error", @now), :scheduler, server: repo)

      assert settlement.disposition == :exhausted
      assert settlement.outcome == "task_failed"
      assert %{state: "exhausted", task_attempts: 3} = delivery_row(conn, id)
    end

    test "a run no longer active leaves the delivery alone", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      id = delivery(conn, w, %{source: "src-a"})
      %{run: run} = claim!(repo, w, @now)

      {:ok, _settled} = Repo.settle_cue_run(finish(run, "ok", @now), :acted, server: repo)
      before = delivery_row(conn, id)

      assert {:error, :run_not_active} =
               Repo.settle_cue_run(finish(run, "error", @now), :scheduler, server: repo)

      assert delivery_row(conn, id) == before
    end

    test "a delivery that left claimed is reported untouched and the run still settles", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      id = delivery(conn, w, %{source: "src-a"})
      %{run: run} = claim!(repo, w, @now)

      exec!(
        conn,
        "UPDATE cue_deliveries SET state = 'expired', outcome = 'lifetime', settled_at = ? " <>
          "WHERE id = ?",
        [stamp(@now), id]
      )

      log =
        capture_log(fn ->
          assert {:ok, {settled, job, settlement}} =
                   Repo.settle_cue_run(finish(run, "ok", @now), :acted, server: repo)

          assert settled.status == "ok"
          assert job.state == "scheduled"
          assert settlement.disposition == :untouched
        end)

      assert log =~ "Cue delivery #{id}"
      assert delivery_row(conn, id).state == "expired"
    end

    test "settle_job_run refuses a cue run, which needs its outcome", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      id = delivery(conn, w, %{source: "src-a"})
      %{run: run} = claim!(repo, w, @now)

      assert {:error, :cue_run} = Repo.settle_job_run(finish(run, "ok", @now), server: repo)
      assert delivery_row(conn, id).state == "claimed"
      assert job_row(conn, w.job_id).state == "running"
    end

    test "a run that is not a cue run is refused by the cue settle", ctx do
      %{repo: repo, conn: conn} = ctx
      w = watcher(conn, ["src-a"])
      attrs = %{run_attrs(w, @now) | trigger: "manual"}
      {:ok, run} = Repo.upsert_job_run(attrs, server: repo)

      assert {:error, :not_a_cue_run} =
               Repo.settle_cue_run(finish(run, "ok", @now), :acted, server: repo)

      assert [["queued"]] = rows(conn, "SELECT status FROM job_runs WHERE id = ?", [run.id])
    end
  end
end
