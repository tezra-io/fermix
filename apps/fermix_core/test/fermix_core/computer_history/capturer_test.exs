defmodule FermixCore.ComputerHistory.CapturerTest do
  @moduledoc """
  MILESTONE_32 §8.4a / §6.4 — the capture rail against a fake compux sidecar
  (`fake_capture_sidecar.pl`). Proves the async event push end-to-end: handshake
  (protocol v6 ack), buffered flush into `Ingest` → `Repo`, protocol-mismatch and
  refused-start degradation, the machine-wide singleton stand-down, and that a
  malformed frame becomes a gap rather than a crash — all with an injected repo
  and an injected lock path so the suite never touches the real machine lock.
  """
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Capturer
  alias FermixCore.Memory.Repo

  @fake Path.expand("fake_capture_sidecar.pl", __DIR__)

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-capturer-#{unique}.db")
    lock_path = Path.join(System.tmp_dir!(), "fermix-ch-capturer-#{unique}.lock")
    repo_name = :"ch_capturer_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm(lock_path)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name, db_path: db_path, lock_path: lock_path, tmp: unique}
  end

  # --- helpers -----------------------------------------------------------

  defp events_file(ctx, frames) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-ch-events-#{ctx.tmp}-#{System.unique_integer([:positive])}.ndjson"
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm(path) end)
    File.write!(path, Enum.map_join(frames, "\n", &Jason.encode!/1) <> "\n")
    path
  end

  defp start_capturer(ctx, opts) do
    {id, opts} = Keyword.pop(opts, :id, :capturer)
    tag = System.unique_integer([:positive])

    defaults = [
      name: :"ch_capturer_#{tag}",
      repo: ctx.repo,
      binary_path: @fake,
      lock_path: ctx.lock_path,
      apps: ["com.apple.Safari"],
      sites: [],
      flush_interval_ms: 25,
      batch_size: 50
    ]

    start_supervised!({Capturer, Keyword.merge(defaults, opts)}, id: id)
  end

  defp stored(repo), do: elem(Repo.computer_history_events_after_id(0, 1_000, server: repo), 1)

  # Bounded async wait: the capture push is genuinely asynchronous (OS subprocess
  # → Port → timed flush → repo write), so a deadline-bounded poll is the correct
  # tool, not a fixed sleep masking a race.
  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_eventually(fun, deadline)
        else
          flunk("condition not reached within deadline")
        end
    end
  end

  defp app_event(seq, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "event",
        "v" => 1,
        "ts" => 1_770_000_000_000 + seq,
        "seq" => seq,
        "boot_id" => "boot-t",
        "app" => %{"bundle_id" => "com.apple.Safari", "name" => "Safari", "pid" => 10},
        "kind" => "app.activated"
      },
      extra
    )
  end

  # --- tests -------------------------------------------------------------

  describe "handshake + event flow" do
    test "acked v6 frames flow through Ingest into the repo", ctx do
      frames = [
        app_event(1),
        app_event(2, %{
          "kind" => "field.value",
          "field_label" => "Search",
          "text" => "hello",
          "char_len" => 5
        })
      ]

      events = events_file(ctx, frames)
      start_capturer(ctx, sidecar_env: [{~c"FAKE_EVENTS_FILE", String.to_charlist(events)}])

      rows =
        eventually(fn ->
          if length(stored(ctx.repo)) >= 2, do: {:ok, stored(ctx.repo)}, else: :retry
        end)

      seqs = rows |> Enum.map(& &1.source_seq) |> Enum.sort()
      assert seqs == [1, 2]
      assert Enum.all?(rows, &(&1.bundle_id == "com.apple.Safari"))
      assert Enum.any?(rows, &(&1.type == "field.value" and &1.text == "hello"))
    end

    test "frames arriving before the ack are buffered, then flushed after the handshake", ctx do
      pre = events_file(ctx, [app_event(1)])
      post = events_file(ctx, [app_event(2)])

      start_capturer(ctx,
        sidecar_env: [
          {~c"FAKE_PRE_ACK_FILE", String.to_charlist(pre)},
          {~c"FAKE_EVENTS_FILE", String.to_charlist(post)}
        ]
      )

      rows =
        eventually(fn ->
          if length(stored(ctx.repo)) >= 2, do: {:ok, stored(ctx.repo)}, else: :retry
        end)

      assert rows |> Enum.map(& &1.source_seq) |> Enum.sort() == [1, 2]
    end
  end

  describe "degradation (fail loud, no crash loop)" do
    test "a protocol-version mismatch degrades and writes nothing", ctx do
      events = events_file(ctx, [app_event(1)])

      pid =
        start_capturer(ctx,
          sidecar_env: [
            {~c"FAKE_PROTO", ~c"5"},
            {~c"FAKE_EVENTS_FILE", String.to_charlist(events)}
          ]
        )

      status =
        eventually(fn ->
          if Capturer.status(pid).mode == :degraded, do: {:ok, Capturer.status(pid)}, else: :retry
        end)

      assert {:protocol_mismatch, %{required: 6, sidecar: 5}} = status.reason
      assert stored(ctx.repo) == []
    end

    test "a refused observe_start degrades", ctx do
      pid = start_capturer(ctx, sidecar_env: [{~c"FAKE_ACK_OK", ~c"false"}])

      status =
        eventually(fn ->
          if Capturer.status(pid).mode == :degraded, do: {:ok, Capturer.status(pid)}, else: :retry
        end)

      assert status.reason == :observe_start_refused
    end

    test "a sidecar that dies before the handshake is retried, then degrades once the budget is spent",
         ctx do
      # The sidecar exits on every observe_start before acking — no handshake ever
      # resets the budget — so bounded retries exhaust and the rail degrades loudly
      # instead of crash-looping the process or the supervisor.
      pid =
        start_capturer(ctx,
          max_restart_attempts: 2,
          restart_backoff_ms: 15,
          sidecar_env: [{~c"FAKE_EXIT_BEFORE_ACK", ~c"1"}]
        )

      status =
        eventually(fn ->
          if Capturer.status(pid).mode == :degraded, do: {:ok, Capturer.status(pid)}, else: :retry
        end)

      assert {:sidecar_restart_exhausted, _status} = status.reason
      # Degraded, not dead: the process stays up so the doctor row/status can
      # report the failure rather than a supervisor restart storm.
      assert Process.alive?(pid)

      rows = stored(ctx.repo)
      # No unverified sidecar events leak (the wire never verified), but the
      # self-authored 'restart' gaps DO survive the degrade — the discontinuity is
      # recorded, never a silent hole.
      assert rows != []
      assert Enum.all?(rows, &(&1.type == "observer.gap" and &1.gap_reason == "restart"))
    end

    test "verified events survive even when a later restart exhausts the budget", ctx do
      # The sidecar acks once and streams a verified event, then dies before acking
      # on every retry until the budget is spent. The verified event must be
      # persisted (flushed on the exit while the wire was still verified), never
      # dropped by the eventual degrade.
      events = events_file(ctx, [app_event(1)])

      sentinel =
        Path.join(
          System.tmp_dir!(),
          "fermix-ch-once-#{ctx.tmp}-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> FermixTestSupport.SafeRm.rm(sentinel) end)

      pid =
        start_capturer(ctx,
          max_restart_attempts: 2,
          restart_backoff_ms: 15,
          sidecar_env: [
            {~c"FAKE_ACK_ONCE", ~c"1"},
            {~c"FAKE_STATE_FILE", String.to_charlist(sentinel)},
            {~c"FAKE_EVENTS_FILE", String.to_charlist(events)}
          ]
        )

      _ =
        eventually(fn ->
          if Capturer.status(pid).mode == :degraded, do: {:ok, :done}, else: :retry
        end)

      rows = stored(ctx.repo)

      assert Enum.any?(rows, &(&1.source_seq == 1 and &1.type == "app.activated")),
             "the verified event was dropped by the exhausted-restart degrade"
    end

    test "a degraded capturer releases the machine-wide lock so a healthy daemon can take over",
         ctx do
      pid = start_capturer(ctx, sidecar_env: [{~c"FAKE_ACK_OK", ~c"false"}])

      _ =
        eventually(fn ->
          if Capturer.status(pid).mode == :degraded, do: {:ok, :done}, else: :retry
        end)

      # The lock file is gone — a standee on the same Mac is no longer blocked.
      refute File.exists?(ctx.lock_path)
      assert Process.alive?(pid)
    end
  end

  describe "gaps are first-class" do
    test "a malformed frame becomes an observer.gap, not a crash", ctx do
      # A valid event, then a line that is not JSON — the capturer must gap it and
      # keep ingesting, never crash the process.
      events = events_file(ctx, [app_event(1)])

      File.write!(
        events,
        File.read!(events) <> "{ not json\n" <> Jason.encode!(app_event(2)) <> "\n"
      )

      pid = start_capturer(ctx, sidecar_env: [{~c"FAKE_EVENTS_FILE", String.to_charlist(events)}])

      rows =
        eventually(fn ->
          rows = stored(ctx.repo)
          if Enum.any?(rows, &(&1.type == "observer.gap")), do: {:ok, rows}, else: :retry
        end)

      assert Process.alive?(pid)
      gap = Enum.find(rows, &(&1.type == "observer.gap"))
      # A per-incarnation gap boot_id (prefix + boot-unique suffix), so a restart's
      # seq-reset never collides with a prior run's gaps under INSERT OR IGNORE.
      assert String.starts_with?(gap.boot_id, "fermix-capturer-")
      assert String.starts_with?(gap.gap_reason, "malformed")
      # The real events on either side still made it in.
      assert Enum.count(rows, &(&1.type == "app.activated")) == 2
    end

    test "an out-of-range ts becomes a gap with a readable reason", ctx do
      # The decoder refuses the stamp; the gap reason has to name the field, not
      # print Elixir tuple syntax into a stored column.
      events = events_file(ctx, [app_event(1), app_event(2, %{"ts" => -1})])

      pid = start_capturer(ctx, sidecar_env: [{~c"FAKE_EVENTS_FILE", String.to_charlist(events)}])

      rows =
        eventually(fn ->
          rows = stored(ctx.repo)
          if Enum.any?(rows, &(&1.type == "observer.gap")), do: {:ok, rows}, else: :retry
        end)

      assert Process.alive?(pid)
      gap = Enum.find(rows, &(&1.type == "observer.gap"))
      assert gap.gap_reason == "malformed:invalid_ts"
      refute gap.gap_reason =~ "{:invalid_field"
    end
  end

  describe "machine-wide singleton" do
    test "a second capturer on the same lock stands down", ctx do
      first = start_capturer(ctx, id: :capturer_a)
      # Force the first's bootstrap (lock acquire) to complete before the second starts.
      assert Capturer.status(first).mode == :capturing

      second = start_capturer(ctx, id: :capturer_b)
      status = Capturer.status(second)

      assert status.mode == :standing_down
      assert status.lock_holder != nil
    end
  end
end
