defmodule FermixChannels.Gateway.IdempotencyDurableTest do
  # M75 B15: inbound event ids live in `memory.db` for their window, so a
  # retry that straddles a restart (or a move of the home, which carries the
  # same file) is still a duplicate. Each test runs its own Repo on its own
  # database file and its own cache, and injects the wall clock the durable
  # rows are stamped with.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixChannels.Gateway.Idempotency
  alias FermixCore.Memory.Repo

  @day_ms 24 * 60 * 60 * 1_000
  @t0 1_790_000_000_000

  setup do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("idempotency-durable")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, @t0)

    %{db_path: Path.join(dir, "memory.db"), clock: clock}
  end

  defp start_repo(ctx, id) do
    name = :"idempotency_repo_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({Repo, name: name, enabled: true, database_path: ctx.db_path},
        id: id
      )
    )

    name
  end

  defp start_cache(ctx, repo, id) do
    name = :"idempotency_#{System.unique_integer([:positive])}"
    table = :"idempotency_table_#{System.unique_integer([:positive])}"
    clock = ctx.clock

    start_supervised!(
      Supervisor.child_spec(
        {Idempotency,
         name: name,
         table: table,
         store: {:repo, repo},
         wall_clock: fn -> :atomics.get(clock, 1) end},
        id: id
      )
    )

    name
  end

  defp set_clock(ctx, ms), do: :atomics.put(ctx.clock, 1, ms)

  defp with_raw_conn(db_path, fun) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)
    :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp count_rows(db_path, where) do
    with_raw_conn(db_path, fn conn ->
      {:ok, stmt} = Sqlite3.prepare(conn, "SELECT count(*) FROM channel_event_ids #{where}")
      {:ok, [[count]]} = Sqlite3.fetch_all(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      count
    end)
  end

  # Sends the sweep the timer would send, then syncs on a call: messages are
  # handled in order, so a returned call proves the sweep ran.
  defp sweep_now(cache) do
    send(Process.whereis(cache), :sweep)
    assert :fresh = Idempotency.check_and_record(:telegram, "sweep-sync-probe", server: cache)
    :ok = Idempotency.forget(:telegram, "sweep-sync-probe", server: cache)
  end

  test "an id recorded before a restart is a duplicate after it", ctx do
    repo = start_repo(ctx, :repo_before)
    cache = start_cache(ctx, repo, :cache_before)

    assert :fresh = Idempotency.check_and_record(:slack, "1714000000.000200", server: cache)

    # A fresh Repo process and a fresh cache on the same database file: what
    # a restart, or the new host after a move, starts with.
    :ok = stop_supervised(:cache_before)
    :ok = stop_supervised(:repo_before)
    repo = start_repo(ctx, :repo_after)
    cache = start_cache(ctx, repo, :cache_after)

    assert :duplicate = Idempotency.check_and_record(:slack, "1714000000.000200", server: cache)
    assert :fresh = Idempotency.check_and_record(:whatsapp, "1714000000.000200", server: cache)
  end

  test "an id is fresh again once its window has passed, and not a moment before", ctx do
    repo = start_repo(ctx, :repo_first)
    cache = start_cache(ctx, repo, :cache_first)
    assert :fresh = Idempotency.check_and_record(:slack, "evt-window", server: cache)
    :ok = stop_supervised(:cache_first)

    set_clock(ctx, @t0 + @day_ms - 1)
    cache = start_cache(ctx, repo, :cache_inside)
    assert :duplicate = Idempotency.check_and_record(:slack, "evt-window", server: cache)
    :ok = stop_supervised(:cache_inside)

    set_clock(ctx, @t0 + @day_ms)
    cache = start_cache(ctx, repo, :cache_past)
    assert :fresh = Idempotency.check_and_record(:slack, "evt-window", server: cache)
    # Renewed for a new window from the moment it was taken in again.
    assert count_rows(ctx.db_path, "WHERE expires_at_ms = #{@t0 + 2 * @day_ms}") == 1
  end

  # The cache answers a known id without the Repo, so with the Repo gone a
  # known id still answers, whether this process recorded it or found it.
  test "a known id never reaches SQLite again", ctx do
    repo = start_repo(ctx, :repo_seed)
    cache = start_cache(ctx, repo, :cache_seed)
    assert :fresh = Idempotency.check_and_record(:slack, "recorded-here", server: cache)
    :ok = stop_supervised(:cache_seed)

    cache = start_cache(ctx, repo, :cache_reader)
    assert :fresh = Idempotency.check_and_record(:slack, "recorded-now", server: cache)
    assert :duplicate = Idempotency.check_and_record(:slack, "recorded-here", server: cache)

    :ok = stop_supervised(:repo_seed)

    assert :duplicate = Idempotency.check_and_record(:slack, "recorded-now", server: cache)
    assert :duplicate = Idempotency.check_and_record(:slack, "recorded-here", server: cache)
  end

  test "forget/3 deletes the durable row, so the next arrival after a restart is fresh", ctx do
    repo = start_repo(ctx, :repo_forget)
    cache = start_cache(ctx, repo, :cache_forget)
    assert :fresh = Idempotency.check_and_record(:whatsapp, "wamid.abc", server: cache)
    assert :ok = Idempotency.forget(:whatsapp, "wamid.abc", server: cache)
    :ok = stop_supervised(:cache_forget)

    cache = start_cache(ctx, repo, :cache_after_forget)
    assert :fresh = Idempotency.check_and_record(:whatsapp, "wamid.abc", server: cache)
  end

  test "a store that cannot answer is an error, and nothing is recorded", ctx do
    repo = :"idempotency_repo_off_#{System.unique_integer([:positive])}"
    start_supervised!({Repo, name: repo, enabled: false, database_path: ctx.db_path})
    cache = start_cache(ctx, repo, :cache_off)

    assert {:error, {:idempotency_store, :disabled}} =
             Idempotency.check_and_record(:slack, "evt-unrecorded", server: cache)

    assert {:error, {:idempotency_store, :disabled}} =
             Idempotency.check_and_record(:slack, "evt-unrecorded", server: cache)
  end

  describe "pruning" do
    test "a prune deletes at most its limit, oldest first, and never a live row", ctx do
      repo = start_repo(ctx, :repo_prune)

      for {id, expiry} <- [{"a", 10}, {"b", 20}, {"c", 30}, {"live", 10_000}] do
        assert {:ok, :fresh} = Repo.claim_inbound_event(:slack, id, @t0, expiry, server: repo)
      end

      assert {:ok, 2} = Repo.prune_inbound_events(@t0 + 100, 2, server: repo)
      assert count_rows(ctx.db_path, "WHERE event_id = 'c'") == 1
      assert {:ok, 1} = Repo.prune_inbound_events(@t0 + 100, 2, server: repo)
      assert {:ok, 0} = Repo.prune_inbound_events(@t0 + 100, 2, server: repo)
      assert count_rows(ctx.db_path, "") == 1
    end

    test "a sweep prunes at most 1,000 expired rows; the next sweep takes the rest", ctx do
      repo = start_repo(ctx, :repo_sweep)
      cache = start_cache(ctx, repo, :cache_sweep)
      assert :fresh = Idempotency.check_and_record(:slack, "live-row", server: cache)

      with_raw_conn(ctx.db_path, fn conn ->
        :ok =
          Sqlite3.execute(conn, """
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1005)
          INSERT INTO channel_event_ids (channel, event_id, recorded_at_ms, expires_at_ms)
          SELECT 'slack', 'old-' || i, #{@t0 - @day_ms}, #{@t0 - 1} FROM n;
          """)
      end)

      sweep_now(cache)
      assert count_rows(ctx.db_path, "WHERE expires_at_ms <= #{@t0}") == 5

      sweep_now(cache)
      assert count_rows(ctx.db_path, "WHERE expires_at_ms <= #{@t0}") == 0
      assert count_rows(ctx.db_path, "WHERE event_id = 'live-row'") == 1
    end
  end
end
