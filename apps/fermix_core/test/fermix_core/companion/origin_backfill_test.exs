defmodule FermixCore.Companion.OriginBackfillTest do
  @moduledoc """
  The timeline rows a scheduled job's or a cue's run wrote before
  `metadata.origin` existed are given the origin their run gives a row today
  (`Companion.OriginBackfill`), and every other row is left as it was.

  `async: false`: the summary line is at info, so one test raises the Logger
  level, a global, while it reads it (AGENTS.md, "Tests under load").
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1, capture_log: 2]
  import FermixTestSupport.CueFixtures

  alias FermixCore.Companion.OriginBackfill
  alias FermixCore.Companion.Timeline
  alias FermixCore.Memory.Repo

  @profile "main"
  @stamp "2026-10-20T08:00:00.000000Z"

  setup do
    start_repo("origin_backfill")
  end

  # --- fixtures ----------------------------------------------------------------

  # A scheduled job named `name`, with the memory source it needs. Returns its id.
  defp job!(conn, name) do
    unique = System.unique_integer([:positive])
    job_id = "job_backfill#{unique}"
    source_id = "src_backfill#{unique}"

    exec!(
      conn,
      "INSERT INTO memory_sources (id, source_type, name, memory_scope) VALUES (?, 'job', ?, ?)",
      [source_id, name, "job:#{job_id}"]
    )

    exec!(
      conn,
      """
      INSERT INTO scheduled_jobs (id, name, schedule_kind, schedule_expr, timezone, task_prompt,
        memory_source_id, created_by_trust)
      VALUES (?, ?, 'interval', '3600', 'Etc/UTC', 'Report it.', ?, 'operator')
      """,
      [job_id, name, source_id]
    )

    job_id
  end

  # A finished run of `job_id` started by `trigger`. `opts`: `:snapshot_name`
  # (the job's name as the run recorded it; no snapshot when absent) and
  # `:cue_delivery_id`. Returns its id.
  defp run!(conn, job_id, trigger, opts \\ []) do
    run_id = "run_#{System.unique_integer([:positive])}"

    snapshot =
      case Keyword.fetch(opts, :snapshot_name) do
        {:ok, name} -> Jason.encode!(%{"job_id" => job_id, "name" => name})
        :error -> nil
      end

    exec!(
      conn,
      """
      INSERT INTO job_runs (id, job_id, session_id, trigger, status, job_config_snapshot_json,
        cue_delivery_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, 'ok', ?, ?, ?, ?)
      """,
      [
        run_id,
        job_id,
        "cron_#{run_id}",
        trigger,
        snapshot,
        Keyword.get(opts, :cue_delivery_id),
        @stamp,
        @stamp
      ]
    )

    run_id
  end

  # A watcher named `name` with its task job. Returns `%{id, job_id}`.
  defp watcher!(conn, name) do
    id = insert_watcher(conn, %{name: name, filter: "none", sources: ["src:#{name}"]})
    [[job_id]] = rows(conn, "SELECT task_job_id FROM cue_watchers WHERE id = ?", [id])
    %{id: id, job_id: job_id}
  end

  # One cue and its delivery to `watcher`. Returns `{cue_id, delivery_id}`.
  defp delivery!(conn, watcher) do
    unique = System.unique_integer([:positive])

    [[cue_id]] =
      rows(
        conn,
        """
        INSERT INTO cues (source_ref, item_id, type, received_at, content_hash, payload,
          payload_bytes, routed_count, last_seen_at)
        VALUES ('src:a', ?, 't', ?, ?, '{}', 2, 1, ?) RETURNING id
        """,
        ["item-#{unique}", @stamp, "h#{unique}", @stamp]
      )

    [[delivery_id]] =
      rows(
        conn,
        """
        INSERT INTO cue_deliveries (cue_id, watcher_id, source_ref, received_at, state,
          ready_at, valid_until)
        VALUES (?, ?, 'src:a', ?, 'acked', ?, ?) RETURNING id
        """,
        [cue_id, watcher.id, @stamp, @stamp, @stamp]
      )

    {cue_id, delivery_id}
  end

  # A run of watcher `watcher`'s task that delivery set off.
  defp cue_run!(conn, watcher) do
    {_cue_id, delivery_id} = delivery!(conn, watcher)
    run!(conn, watcher.job_id, "cue", cue_delivery_id: delivery_id)
  end

  # A run of follow-up job `job_id` that watcher `watcher` set off, through the
  # trigger its claim wrote the run's id on.
  defp follow_up_run!(conn, watcher, job_id) do
    {cue_id, delivery_id} = delivery!(conn, watcher)
    run_id = run!(conn, job_id, "watcher")

    exec!(
      conn,
      """
      INSERT INTO cue_follow_up_triggers (id, watcher_id, delivery_id, cue_id, job_id, mode,
        state, run_id, created_at)
      VALUES (?, ?, ?, ?, ?, 'auto', 'started', ?, ?)
      """,
      ["cft_#{run_id}", watcher.id, delivery_id, cue_id, job_id, run_id, @stamp]
    )

    run_id
  end

  defp store_opts(repo), do: [repo: repo, agent_id: "agent-a", owner_id: "owner-a"]

  # A row a run's send wrote: its text under `job:<run id>`, or a part of it
  # under `job:<run id>:<part id>`. Returns its server_seq.
  defp sent!(repo, key, attrs \\ %{}) do
    attrs = Map.merge(%{role: "assistant", kind: "text", content: "Done: #{key}"}, attrs)
    {:ok, {:created, row}} = Timeline.append_proactive(@profile, key, attrs, store_opts(repo))
    row.server_seq
  end

  defp appended!(repo, attrs) do
    {:ok, row} = Timeline.append(@profile, attrs, store_opts(repo))
    row.server_seq
  end

  defp backfill(repo, opts \\ []), do: OriginBackfill.run([repo: repo] ++ opts)

  # Every row's metadata as a history page hands it to a client, by server_seq.
  defp page_metadata(repo) do
    {:ok, page} = Timeline.history_page(@profile, store_opts(repo) ++ [limit: 200])
    Map.new(page.messages, &{&1.server_seq, &1.metadata})
  end

  # Every row's stored metadata, byte for byte.
  defp stored(conn) do
    conn
    |> rows("SELECT server_seq, metadata_json FROM mobile_timeline ORDER BY server_seq")
    |> Map.new(fn [seq, json] -> {seq, json} end)
  end

  defp origin(kind, name), do: %{"kind" => kind, "name" => name}

  # --- each trigger ------------------------------------------------------------

  test "a row each kind of run sent gets the origin that run gives a row today",
       %{repo: repo, conn: conn} do
    brief = job!(conn, "Daily brief")
    scheduled = run!(conn, brief, "schedule", snapshot_name: "Morning brief")
    manual = run!(conn, brief, "manual")

    inbox = watcher!(conn, "inbox-watch")
    cue = cue_run!(conn, inbox)

    deploys = watcher!(conn, "deploy-watch")
    follow_up = follow_up_run!(conn, deploys, job!(conn, "Fix the deploy"))

    scheduled_seq = sent!(repo, "job:#{scheduled}")
    manual_seq = sent!(repo, "job:#{manual}")
    cue_seq = sent!(repo, "job:#{cue}")
    picture_seq = sent!(repo, "job:#{cue}:part-1", %{kind: "media", content: "a chart"})
    follow_up_seq = sent!(repo, "job:#{follow_up}")

    assert {:ok, %{filled: 5, left: 0}} = backfill(repo)

    metadata = page_metadata(repo)
    # The job's name as the run recorded it, not as it reads now.
    assert metadata[scheduled_seq] == %{"origin" => origin("job", "Morning brief")}
    # A run that recorded none: the job's name now.
    assert metadata[manual_seq] == %{"origin" => origin("job", "Daily brief")}
    # The watcher's name, never its task job's.
    assert metadata[cue_seq] == %{"origin" => origin("cue", "inbox-watch")}
    assert metadata[picture_seq] == %{"origin" => origin("cue", "inbox-watch")}
    # A follow-up names the watcher that set it off, never its own job.
    assert metadata[follow_up_seq] == %{"origin" => origin("cue", "deploy-watch")}
  end

  test "every other key stays, and the row stores what a row written today stores",
       %{repo: repo, conn: conn} do
    run = run!(conn, job!(conn, "Daily brief"), "schedule", snapshot_name: "Daily brief")
    old_seq = sent!(repo, "job:#{run}", %{metadata: %{"turn_id" => "turn-1"}})

    today_seq =
      appended!(repo, %{
        role: "assistant",
        kind: "text",
        content: "written today",
        metadata: %{"turn_id" => "turn-1", "origin" => origin("job", "Daily brief")}
      })

    assert {:ok, %{filled: 1}} = backfill(repo)

    rows = stored(conn)
    assert Jason.decode!(rows[old_seq])["turn_id"] == "turn-1"
    assert rows[old_seq] == rows[today_seq]
  end

  # --- rows left as they were --------------------------------------------------

  test "a row with no run, no watcher, no name or an origin already stays as it was",
       %{repo: repo, conn: conn} do
    brief = job!(conn, "Daily brief")

    gone = watcher!(conn, "gone-watch")
    gone_cue = cue_run!(conn, gone)
    gone_follow_up = follow_up_run!(conn, gone, job!(conn, "Fix it"))
    exec!(conn, "DELETE FROM cue_watchers WHERE id = ?", [gone.id])

    pruned = watcher!(conn, "pruned-watch")
    pruned_cue = cue_run!(conn, pruned)
    exec!(conn, "DELETE FROM cue_deliveries WHERE watcher_id = ?", [pruned.id])

    other = run!(conn, brief, "replay", snapshot_name: "Daily brief")
    named = run!(conn, brief, "schedule", snapshot_name: "Daily brief")

    # A watcher's notice (no key), a reply, a call's row and a phone message.
    appended!(repo, %{role: "assistant", kind: "text", content: "Watcher x reached its cap"})
    appended!(repo, %{role: "assistant", content: "Sure.", metadata: %{"turn_id" => "t1"}})
    sent!(repo, "call:abc", %{metadata: %{"call" => %{"state" => "ended"}}})
    appended!(repo, %{role: "user", content: "hi", client_msg_id: "c1"})

    sent!(repo, "job:#{gone_cue}")
    sent!(repo, "job:#{gone_follow_up}")
    sent!(repo, "job:#{pruned_cue}")
    sent!(repo, "job:run_never_recorded")
    sent!(repo, "job:#{other}")
    sent!(repo, "job:#{named}", %{metadata: %{"origin" => origin("cue", "kept")}})

    before = stored(conn)

    assert {:ok, %{filled: 0, left: 5}} = backfill(repo)
    assert stored(conn) == before
  end

  test "a second pass changes nothing", %{repo: repo, conn: conn} do
    run = run!(conn, job!(conn, "Daily brief"), "manual")
    sent!(repo, "job:#{run}")
    sent!(repo, "job:run_never_recorded")

    assert {:ok, %{filled: 1, left: 1}} = backfill(repo)
    after_first = stored(conn)

    assert {:ok, %{filled: 0, left: 1}} = backfill(repo)
    assert stored(conn) == after_first
  end

  # --- batches -----------------------------------------------------------------

  test "the pass walks batch after batch until every row is read", %{repo: repo, conn: conn} do
    brief = job!(conn, "Daily brief")

    seqs =
      for _index <- 1..5 do
        sent!(repo, "job:run_never_recorded_#{System.unique_integer([:positive])}")
        sent!(repo, "job:#{run!(conn, brief, "schedule", snapshot_name: "Daily brief")}")
      end

    assert {:ok, %{filled: 5, left: 5}} = backfill(repo, batch_size: 2)

    metadata = page_metadata(repo)
    assert Enum.all?(seqs, &(metadata[&1] == %{"origin" => origin("job", "Daily brief")}))
  end

  test "a pass that reaches its batch cap stops, and the next start carries on",
       %{repo: repo, conn: conn} do
    brief = job!(conn, "Daily brief")
    for _index <- 1..3, do: sent!(repo, "job:#{run!(conn, brief, "manual")}")

    log =
      capture_log(fn ->
        assert {:ok, %{filled: 2, left: 0}} = backfill(repo, batch_size: 1, max_batches: 2)
      end)

    assert log =~ "stopped at its cap of 2 batches"
    assert {:ok, %{filled: 1, left: 0}} = backfill(repo, batch_size: 1, max_batches: 2)
  end

  # --- the boot task -----------------------------------------------------------

  test "one line says how many rows were filled in", %{repo: repo, conn: conn} do
    run = run!(conn, job!(conn, "Daily brief"), "manual")
    sent!(repo, "job:#{run}")
    sent!(repo, "job:run_never_recorded")

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, %{filled: 1, left: 1}} = backfill(repo)
      end)

    assert log =~
             "said where 1 earlier message from a job or a cue came from; " <>
               "1 left without a run, watcher or name on record"
  end

  test "a home with memory off has no timeline to fill" do
    unique = System.unique_integer([:positive])
    repo = :"origin_backfill_off_#{unique}"
    path = Path.join(System.tmp_dir!(), "fermix-origin-off-#{unique}.db")

    start_supervised!(
      Supervisor.child_spec({Repo, name: repo, enabled: false, database_path: path}, id: repo)
    )

    assert {:ok, %{filled: 0, left: 0}} = backfill(repo)
  end

  test "the boot child does nothing where it is switched off" do
    assert OriginBackfill.start_link(enabled: false) == :ignore
  end
end
