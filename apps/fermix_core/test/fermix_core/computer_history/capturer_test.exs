defmodule FermixCore.ComputerHistory.CapturerTest do
  @moduledoc """
  MILESTONE_32 §8.4a / §6.4 — the capture rail against a fake compux sidecar
  (`fake_capture_sidecar.pl`). Proves the async event push end-to-end: handshake
  (the protocol ack), buffered flush into `Ingest` → `Repo`, protocol-mismatch and
  refused-start degradation, the machine-wide singleton stand-down, and that a
  malformed frame becomes a gap rather than a crash — all with an injected repo
  and an injected lock path so the suite never touches the real machine lock.
  """
  # async: false — the flush-accounting case lowers the global Logger level, which
  # config/test.exs pins to :warning.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory.Capturer
  alias FermixCore.ComputerHistory.Controller
  alias FermixCore.Memory.Repo

  @fake Path.expand("fake_capture_sidecar.pl", __DIR__)

  # The rail requires exactly the wire the compiled-in library speaks. Pinned here
  # rather than written as a number, because a hand-written integer in the test is
  # how the two constants drift apart in the first place; the test below proves
  # the capturer agrees.
  @protocol Compux.Protocol.protocol_version()

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
      flush_interval_ms: 25,
      batch_size: 50,
      # The Capturer re-reads the feature's resolver at every start; these cases
      # run the rail itself, on any host, whatever the app env says.
      operative_fun: fn -> true end
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

  defp read_pid_file(path) do
    with {:ok, contents} <- File.read(path),
         {os_pid, _rest} <- Integer.parse(String.trim(contents)) do
      {:ok, os_pid}
    else
      _not_yet -> :retry
    end
  end

  defp os_process_alive?(os_pid) do
    {_output, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  # --- tests -------------------------------------------------------------

  # Open → close on every path. A degrade is the one path that can run moments
  # after the OS process was spawned, and the handle has to be in state ALREADY
  # when it does, or the sidecar is dropped rather than reaped and the capturer
  # sits `:degraded` holding an orphan — the leak `Compux.Port` exists to prevent.
  # The fake records its own pid, so this asserts the process is GONE rather than
  # merely forgotten.
  describe "the spawned sidecar is reaped on every exit" do
    test "a capturer that degrades before any ack leaves no live OS process", ctx do
      pid_file =
        Path.join(
          System.tmp_dir!(),
          "fermix-ch-pid-#{ctx.tmp}-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> FermixTestSupport.SafeRm.rm(pid_file) end)

      # Never answers `observe_start`, so it stays ALIVE until something kills it:
      # a capturer that merely forgot the handle would leave this process running.
      pid =
        start_capturer(ctx,
          handshake_timeout_ms: 150,
          sidecar_env: [
            {~c"FAKE_SILENT", ~c"1"},
            {~c"FAKE_PID_FILE", String.to_charlist(pid_file)}
          ]
        )

      os_pid = eventually(fn -> read_pid_file(pid_file) end)

      eventually(fn ->
        if Capturer.status(pid).mode == :degraded, do: {:ok, :degraded}, else: :retry
      end)

      eventually(fn -> if os_process_alive?(os_pid), do: :retry, else: {:ok, :reaped} end)
    end
  end

  describe "handshake + event flow" do
    # One constant, two halves: the capture rail's required version and the
    # library's own. They live in different modules and are compared only here, so
    # without this a protocol bump that misses one of them ships a capture rail
    # that degrades on every healthy sidecar.
    test "the required capture protocol equals the library's own", ctx do
      pid = start_capturer(ctx, sidecar_env: [{~c"FAKE_PROTO", ~c"#{@protocol + 1}"}])

      status =
        eventually(fn ->
          if Capturer.status(pid).mode == :degraded, do: {:ok, Capturer.status(pid)}, else: :retry
        end)

      assert {:protocol_mismatch, %{required: @protocol}} = status.reason
    end

    test "acked frames flow through Ingest into the repo", ctx do
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

    # M32.1 §2.1/§2.2 end to end, through the real Port: the recorder's browser
    # frames land under the app allowlist alone, the URL arrives stripped, a private
    # navigation never lands, and a browser value the recorder could not classify
    # keeps its row without its text. The unknown-state field frame is deliberately
    # HOSTILE — the sidecar contract says it never sends text for a non-not_private
    # window, and the store must prove that rather than trust it.
    test "browser frames land stripped, gated and accounted for", ctx do
      browser = fn seq, extra ->
        app_event(
          seq,
          Map.merge(
            %{"app" => %{"bundle_id" => "com.apple.Safari", "name" => "Safari", "pid" => 10}},
            extra
          )
        )
      end

      frames = [
        browser.(1, %{
          "kind" => "browser.navigated",
          "url" => "https://mail.example.com/u/0/inbox?token=abc#t9",
          "host" => "mail.example.com",
          "page_title" => "Inbox",
          "window_ref" => "11",
          "tab_ref" => "21",
          "private_state" => "not_private"
        }),
        browser.(2, %{
          "kind" => "browser.navigated",
          "url" => "https://private.example/secret",
          "host" => "private.example",
          "window_ref" => "12",
          "tab_ref" => "22",
          "private_state" => "private"
        }),
        browser.(3, %{
          "kind" => "field.value",
          "browser_id" => "com.apple.Safari",
          "window_ref" => "11",
          "tab_ref" => "21",
          "private_state" => "unknown",
          "text" => "typed-into-an-unclassified-window",
          "char_len" => 33
        }),
        browser.(4, %{
          "kind" => "observer.gap",
          "gap_reason" => "private_unknown",
          "gap_from_ts" => 1_770_000_000_000,
          "gap_to_ts" => 1_770_000_001_000
        })
      ]

      events = events_file(ctx, frames)
      start_capturer(ctx, sidecar_env: [{~c"FAKE_EVENTS_FILE", String.to_charlist(events)}])

      rows =
        eventually(fn ->
          if length(stored(ctx.repo)) >= 3, do: {:ok, stored(ctx.repo)}, else: :retry
        end)

      by_seq = Map.new(rows, &{&1.source_seq, &1})
      assert map_size(by_seq) == 3

      assert by_seq[1].url == "https://mail.example.com/u/0/inbox"
      assert by_seq[1].page_title == "Inbox"

      # The private navigation is absent from the store, not filtered on read.
      refute Map.has_key?(by_seq, 2)
      refute Enum.any?(rows, &(&1.host == "private.example"))

      assert by_seq[3].text == nil
      assert by_seq[3].content_withheld == 1
      assert by_seq[3].char_len == 33

      assert by_seq[4].gap_reason == "private_unknown"
      assert by_seq[4].bundle_id == "com.apple.Safari"
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

  # `collapsed` (and `dropped`) were computed and thrown away: a spool that quietly
  # loses 99% of its frames to the allowlist or the title collapse looked exactly
  # like a capture gap. Counts only — never a title, never any content (§15.1).
  # An admission refusal prints BY KIND: "the recorder keeps sending private
  # frames" and "the recorder keeps sending unusable addresses" are different
  # problems, and one total would hide which.
  test "a flush that dropped, collapsed or refused rows accounts for it, without content", ctx do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    frames = [
      app_event(1),
      app_event(2, %{
        "kind" => "window.title_changed",
        "app" => %{"bundle_id" => "com.evil.Keylogger", "name" => "K", "pid" => 11},
        "window_title" => "secret-window-title"
      }),
      app_event(3, %{
        "kind" => "browser.navigated",
        "url" => "https://private.example/secret-page",
        "private_state" => "private"
      })
    ]

    events = events_file(ctx, frames)

    log =
      capture_log([level: :debug], fn ->
        start_capturer(ctx, sidecar_env: [{~c"FAKE_EVENTS_FILE", String.to_charlist(events)}])

        eventually(fn ->
          if stored(ctx.repo) == [], do: :retry, else: {:ok, :written}
        end)
      end)

    assert log =~ "computer_history ingest:"
    assert log =~ "dropped 1"
    assert log =~ "refused private 1"
    refute log =~ "secret-window-title"
    refute log =~ "secret-page"
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

      assert {:protocol_mismatch, %{required: @protocol, sidecar: 5}} = status.reason
      assert stored(ctx.repo) == []
    end

    # The cached release sidecar (compux 0.7.3, protocol 5) has no `observe_start`
    # verb: it answers the unknown action with a POSITIONAL frame carrying no
    # "type", which the decoder refuses. Filed as a gap, the capturer waited
    # forever for an ack that can never come — heartbeating the machine-wide lock
    # the whole time, so the other daemon on the Mac stood down for good.
    test "a typeless reply to observe_start is an old-sidecar mismatch, not a gap", ctx do
      pid = start_capturer(ctx, sidecar_env: [{~c"FAKE_TYPELESS_ACK", ~c"1"}])

      status =
        eventually(fn ->
          if Capturer.status(pid).mode == :degraded, do: {:ok, Capturer.status(pid)}, else: :retry
        end)

      assert status.reason == {:protocol_mismatch, %{required: @protocol, sidecar: :pre_v6}}
      # Released, so a healthy daemon on this Mac can take over.
      refute File.exists?(ctx.lock_path)
      # The wire was never verified, so there is no captured discontinuity to
      # record: a mismatch is a degrade, never an observer.gap.
      assert stored(ctx.repo) == []
      assert Process.alive?(pid)
    end

    test "a sidecar that never answers observe_start degrades at the handshake deadline", ctx do
      pid =
        start_capturer(ctx,
          handshake_timeout_ms: 400,
          sidecar_env: [{~c"FAKE_SILENT", ~c"1"}]
        )

      # Not "running": an unacked wire is a handshake in progress, and /history
      # status has to say so rather than claim capture is live.
      assert Capturer.status(pid).mode == :handshaking

      status =
        eventually(fn ->
          if Capturer.status(pid).mode == :degraded, do: {:ok, Capturer.status(pid)}, else: :retry
        end)

      assert status.reason == :handshake_timeout
      refute File.exists?(ctx.lock_path)
      assert Process.alive?(pid)
    end

    test "a handshake deadline from a superseded sidecar open is ignored", ctx do
      # The first sidecar dies before acking and the retry acks cleanly. The first
      # open's deadline still fires afterwards, and it must not tear down a
      # healthy, capturing rail — it belongs to an incarnation that is gone.
      events = events_file(ctx, [app_event(1)])

      first =
        Path.join(
          System.tmp_dir!(),
          "fermix-ch-first-#{ctx.tmp}-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> FermixTestSupport.SafeRm.rm(first) end)

      pid =
        start_capturer(ctx,
          handshake_timeout_ms: 400,
          restart_backoff_ms: 15,
          sidecar_env: [
            {~c"FAKE_DIE_FIRST", ~c"1"},
            {~c"FAKE_STATE_FILE", String.to_charlist(first)},
            {~c"FAKE_EVENTS_FILE", String.to_charlist(events)}
          ]
        )

      _ =
        eventually(fn ->
          if Capturer.status(pid).mode == :capturing, do: {:ok, :done}, else: :retry
        end)

      # The stale timer firing IS the subject: wait for the capturer to report
      # that it ignored one (an observable count, never a fixed sleep), then
      # prove the healthy rail survived it.
      _ =
        eventually(fn ->
          if Capturer.status(pid).stale_deadlines_ignored >= 1, do: {:ok, :done}, else: :retry
        end)

      assert Capturer.status(pid).mode == :capturing
      assert Enum.any?(stored(ctx.repo), &(&1.source_seq == 1))
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

    test "a typeless frame AFTER a clean handshake is still a gap", ctx do
      # Once the handshake verified the wire, an unrecognized line is a hole in
      # the record — not a verdict on the protocol. Gap it and keep capturing.
      events =
        events_file(ctx, [
          app_event(1),
          %{"ok" => false, "error" => "unknown action"},
          app_event(2)
        ])

      pid = start_capturer(ctx, sidecar_env: [{~c"FAKE_EVENTS_FILE", String.to_charlist(events)}])

      rows =
        eventually(fn ->
          rows = stored(ctx.repo)
          if Enum.any?(rows, &(&1.type == "observer.gap")), do: {:ok, rows}, else: :retry
        end)

      assert Capturer.status(pid).mode == :capturing
      gap = Enum.find(rows, &(&1.type == "observer.gap"))
      assert gap.gap_reason =~ "missing_frame_type"
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

      # Force the first's bootstrap (lock acquire) to complete before the second
      # starts; the mode reads :capturing only once the handshake is acked.
      _ =
        eventually(fn ->
          if Capturer.status(first).mode == :capturing, do: {:ok, :done}, else: :retry
        end)

      second = start_capturer(ctx, id: :capturer_b)
      status = Capturer.status(second)

      assert status.mode == :standing_down
      assert status.lock_holder != nil
    end

    test "a standee takes over once the holder degrades and releases the lock", ctx do
      # §8.6 end to end: the holder's sidecar never answers, so it degrades and
      # releases; the daemon standing down acquires on its next tick. Without a
      # bounded handshake the holder held the lock forever and NOBODY captured.
      events = events_file(ctx, [app_event(1)])

      holder =
        start_capturer(ctx,
          id: :capturer_holder,
          handshake_timeout_ms: 300,
          sidecar_env: [{~c"FAKE_SILENT", ~c"1"}]
        )

      assert Capturer.status(holder).mode == :handshaking

      standee =
        start_capturer(ctx,
          id: :capturer_standee,
          reacquire_interval_ms: 25,
          sidecar_env: [{~c"FAKE_EVENTS_FILE", String.to_charlist(events)}]
        )

      assert Capturer.status(standee).mode == :standing_down

      _ =
        eventually(
          fn ->
            if Capturer.status(standee).mode == :capturing, do: {:ok, :done}, else: :retry
          end,
          5_000
        )

      assert Capturer.status(holder).mode == :degraded

      # And it is really capturing: the standee's own sidecar events land.
      _ =
        eventually(fn ->
          if Enum.any?(stored(ctx.repo), &(&1.source_seq == 1)), do: {:ok, :done}, else: :retry
        end)
    end
  end

  # `/history status` is what an unconfirmed `/history off` tells the owner to
  # check, so "not running" must mean the process is gone, never merely busy.
  describe "status/2" do
    test "a Capturer that does not answer in time is not reported as not running" do
      busy = start_supervised!({Agent, fn -> :ok end}, id: :busy)
      :ok = :sys.suspend(busy)

      try do
        assert %{mode: :not_answering} = Capturer.status(busy, 50)
      after
        :sys.resume(busy)
      end
    end

    # Rule 6: a malformed timeout fails at the call, never reads as a
    # recorder that is not running.
    test "a malformed timeout is refused at the call" do
      for timeout <- [-1, "5000"] do
        error = assert_raise FunctionClauseError, fn -> Capturer.status(:absent, timeout) end
        assert {error.module, error.function, error.arity} == {Capturer, :status, 2}
      end
    end

    # Regression pin, not a failing-first test: a Capturer that is gone still
    # reads as not running.
    test "a Capturer that is gone is reported as not running" do
      absent = :"absent_ch_capturer_#{System.unique_integer([:positive])}"

      assert %{mode: :not_running} = Capturer.status(absent)
    end
  end

  # CH-4: a Capturer that crashed just as `/history off` ran was restarted by its
  # DynamicSupervisor after the Controller's `whereis` had found nothing, and it
  # kept capturing until the next boot. Every start now re-reads the one
  # resolver, so a restart after the flip declines.
  describe "a restart racing /history off (CH-4)" do
    test "a Capturer its DynamicSupervisor restarts after the feature is off stays down", ctx do
      operative = start_supervised!({Agent, fn -> true end}, id: :operative)
      operative_fun = fn -> Agent.get(operative, & &1) end
      sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :capturer_sup)
      name = :"ch_capturer_#{System.unique_integer([:positive])}"

      opts = [
        name: name,
        repo: ctx.repo,
        binary_path: @fake,
        lock_path: ctx.lock_path,
        apps: ["com.apple.Safari"],
        operative_fun: operative_fun
      ]

      {:ok, pid} = DynamicSupervisor.start_child(sup, {Capturer, opts})
      ref = Process.monitor(pid)

      # Hold the crashed Capturer's EXIT in the DynamicSupervisor's mailbox: the
      # window in which the Controller's `whereis` finds no process (check 13).
      :ok = :sys.suspend(sup)

      try do
        capture_log(fn ->
          catch_exit(GenServer.call(pid, :crash))
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
        end)

        # `/history off`: the flip, then the Controller's reconcile finds nothing.
        Agent.update(operative, fn _operative -> false end)

        controller =
          start_supervised!(
            {Controller,
             name: :"ch_ctrl_#{System.unique_integer([:positive])}",
             dynamic_supervisor: sup,
             operative_fun: operative_fun,
             installed_fun: fn -> true end,
             children: [%{name: name, spec: {Capturer, opts}}]}
          )

        assert :ok = Controller.reconcile(controller)
      after
        :sys.resume(sup)
      end

      # Queued behind the EXIT, so the restart has been decided when this answers.
      assert %{active: 0} = DynamicSupervisor.count_children(sup)
      assert Process.whereis(name) == nil
    end
  end
end
