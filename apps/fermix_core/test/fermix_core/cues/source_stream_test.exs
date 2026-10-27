defmodule FermixCore.Cues.Source.StreamTest do
  # What every stream does, whatever its service sends: connecting, routing
  # items by words, liveness, the flush, the budget and the notices. One worker
  # per test on its own temp Repo, with a stand-in transport the test drives by
  # hand (FakeCueTransport; the worker's messages from a socket are crafted
  # here), a stand-in live dispatcher that tells the test what it was handed
  # (FakeLiveFilters), a hand-driven clock and captured timers: no network, no
  # real time. The source is a stream that signs in with nothing, so no secret
  # is read; signing in, reading frames and the service's errors have their own
  # file.
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Source.Stream
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.FakeCueTransport
  alias FermixTestSupport.FakeLiveFilters
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-12 14:00:00Z]
  @url "wss://quotes.example.net/live"
  @wait_ms 10_000

  # A Repo in front of the test's own that takes every flush's write of the
  # source's row (the one with a last good time) and never answers it, and
  # forwards everything else: the store held up behind a long write, as the
  # stream sees it.
  defmodule TouchStallingRepo do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def handle_call({:cues, CuesSql, {:source_touch, _ref, attrs, _now}}, _from, state)
        when is_map_key(attrs, :last_good_at),
        do: {:noreply, state}

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.forward_to, request), state}
  end

  setup do
    ctx = start_repo("stream")
    ref = "quotes-#{System.unique_integer([:positive])}"
    clock = start_supervised!({Agent, fn -> @now end}, id: :clock)
    live = start_supervised!({FakeLiveFilters, test: self()})
    watcher = insert_watcher(ctx.conn, %{filter: "llm", sources: [ref], listen_for: ["hgft"]})

    TelemetryCapture.attach([[:fermix, :cue, :source], [:fermix, :cue, :lifecycle]],
      source_ref: ref
    )

    Map.merge(ctx, %{ref: ref, clock: clock, live: live, watcher: watcher})
  end

  # --- helpers ---------------------------------------------------------------

  # Resolved from a config section as the daemon resolves it.
  defp source(ctx, overrides) do
    section = Map.merge(%{"kind" => "stream", "url" => @url, "id_path" => "id"}, overrides)
    cues = Config.normalize(%{"sources" => %{ctx.ref => section}})
    {:ok, source} = Config.source(ctx.ref, cues)
    source
  end

  defp start_stream(ctx, overrides \\ %{}, worker_opts \\ []) do
    test = self()

    opts = [
      source: source(ctx, overrides),
      repo: ctx.repo,
      clock: fn -> Agent.get(ctx.clock, & &1) end,
      monotonic_ms: fn -> 0 end,
      schedule: fn message, ms -> send(test, {:scheduled, message, ms}) end,
      transport: FakeCueTransport,
      transport_opts: [test: test],
      live: ctx.live,
      admit: fn ref, n, _now_ms -> send(test, {:admit, ref, n}) && n end,
      notify: fn ref, kind, data, _opts -> send(test, {:notice, ref, kind, data}) && :sent end
    ]

    pid = start_supervised!({Stream, Keyword.merge(opts, worker_opts)})
    {pid, scheduled(:connect, 0)}
  end

  defp scheduled(kind, expected_ms) do
    assert_receive {:scheduled, {:timer, ^kind, _token} = message, ^expected_ms}
    message
  end

  # Delivers a message by hand and waits until the worker handled it.
  defp deliver(pid, message) do
    send(pid, message)
    _state = :sys.get_state(pid)
    :ok
  end

  defp dial(pid, message) do
    deliver(pid, message)
    assert_receive {:dialed, url, socket, opts}
    {url, socket, opts}
  end

  defp connect(pid, message) do
    {url, socket, opts} = dial(pid, message)
    deliver(pid, {:cue_stream, socket, :connected})
    {url, socket, opts}
  end

  defp set_clock(ctx, at), do: Agent.update(ctx.clock, fn _old -> at end)

  defp advance(ctx, seconds), do: Agent.update(ctx.clock, &DateTime.add(&1, seconds, :second))

  defp tick(id, symbol \\ "HGFT"), do: %{"id" => id, "symbol" => symbol, "price" => "41.20"}

  defp frame(pid, socket, messages),
    do: deliver(pid, {:cue_stream, socket, {:frame, {:text, Jason.encode!(messages)}}})

  defp flush(pid), do: deliver(pid, scheduled(:flush, 10_000))

  # What the stream offered the live dispatcher, by item id and watchers.
  defp offered(ctx) do
    ref = ctx.ref
    assert_receive {:live_offer, ^ref, offers}, @wait_ms
    Enum.map(offers, fn {item, watchers} -> {item.item_id, watchers} end)
  end

  defp source_row(ctx) do
    {:ok, row} = Repo.cues_call(CuesSql, {:get_source, ctx.ref}, server: ctx.repo)
    row
  end

  defp counts(ctx) do
    {:ok, counts} =
      Repo.cues_call(CuesSql, {:counts_window, "source", @now}, server: ctx.repo)

    Map.get(counts, ctx.ref, %{})
  end

  defp seed_last_good(ctx, at) do
    {:ok, _row} =
      Repo.cues_call(
        CuesSql,
        {:source_touch, ctx.ref, %{last_good_at: at, status: "connected"}, at},
        server: ctx.repo
      )
  end

  # Stored times come back with microseconds.
  defp assert_same_time(stored, expected), do: assert(DateTime.compare(stored, expected) == :eq)

  # --- connecting and routing -------------------------------------------------------

  describe "connecting and routing" do
    test "an item is offered to the watcher its words match; the flush writes the last good " <>
           "time; a drop reconnects, and a repeat is offered again",
         ctx do
      %{ref: ref, watcher: watcher} = ctx
      {pid, first} = start_stream(ctx)

      # A stream that signs in with nothing sends nothing on the upgrade.
      {url, socket, opts} = connect(pid, first)
      assert url == @url
      assert opts[:headers] == []
      assert opts[:messages] == []
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :connect}}

      frame(pid, socket, [tick("t-4101")])
      assert offered(ctx) == [{"t-4101", [watcher]}]
      assert_received {:admit, ^ref, 1}
      assert source_row(ctx).status == "connected"
      flush(pid)
      row = source_row(ctx)
      assert_same_time(row.last_good_at, @now)
      assert row.cursor == nil

      # The connection drops 30 s later, and comes back two minutes after that.
      advance(ctx, 30)
      send(socket, {:die, {:remote_closed, 1000}})
      reconnect = scheduled(:connect, 1_000)
      assert source_row(ctx).status == "reconnecting"

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, attempt: 1}}

      advance(ctx, 120)
      {url, socket, _opts} = connect(pid, reconnect)
      assert url == @url
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :reconnect}}

      # A repeat is judged again; its pass meets the stored identity.
      frame(pid, socket, [tick("t-4101"), tick("t-4102")])
      assert offered(ctx) == [{"t-4101", [watcher]}, {"t-4102", [watcher]}]
      assert [[0]] = rows(ctx.conn, "SELECT count(*) FROM cues")
    end

    test "an unmatched item is counted, never offered; none and wordless watchers get " <>
           "nothing; the hour's counts are flushed",
         ctx do
      ref = ctx.ref
      _none = insert_watcher(ctx.conn, %{filter: "none", sources: [ref]})
      _silent = insert_watcher(ctx.conn, %{filter: "llm", sources: [ref], listen_for: []})
      {pid, first} = start_stream(ctx)
      {_url, socket, _opts} = connect(pid, first)

      frame(pid, socket, [tick("t-1"), tick("t-2", "QZRX"), %{"symbol" => "HGFT"}])

      assert offered(ctx) == [{"t-1", [ctx.watcher]}]
      assert_received {:admit, ^ref, 1}
      flush(pid)

      assert counts(ctx) == %{"received" => 3, "unmatched" => 1, "invalid" => 1}

      assert_received {:telemetry, [:fermix, :cue, :lifecycle], %{count: 1},
                       %{phase: :unmatched, source_ref: ^ref}}

      assert_received {:telemetry, [:fermix, :cue, :lifecycle], %{count: 1},
                       %{phase: :rejected, source_ref: ^ref}}
    end

    test "the rate buckets apply to matched items, and the rest are counted rate_limited", ctx do
      ref = ctx.ref
      test = self()
      admit = fn ^ref, n, _now_ms -> send(test, {:admit, ref, n}) && n - 1 end
      {pid, first} = start_stream(ctx, %{}, admit: admit)
      {_url, socket, _opts} = connect(pid, first)

      frame(pid, socket, [tick("t-1"), tick("t-2", "QZRX"), tick("t-3")])

      assert offered(ctx) == [{"t-1", [ctx.watcher]}]
      assert_received {:admit, ^ref, 2}
      flush(pid)
      assert %{"rate_limited" => 1, "unmatched" => 1} = counts(ctx)
    end

    test "the watchers go to the live dispatcher at connect and on every flush, with what a " <>
           "live call needs",
         ctx do
      %{ref: ref, watcher: watcher} = ctx
      _none = insert_watcher(ctx.conn, %{filter: "none", sources: [ref]})
      {pid, first} = start_stream(ctx)
      connect(pid, first)

      assert_receive {:live_watchers, ^ref, [spec]}
      assert %{id: ^watcher, filter_budget: 0, filter_retry_at: nil, used: 0} = spec
      assert %{instructions: [], examples: []} = spec

      flush(pid)
      assert_receive {:live_watchers, ^ref, [%{id: ^watcher}]}
    end
  end

  # --- the source's row and a slow store ----------------------------------------------

  describe "the source's row" do
    # A write of the source's row that fails closes the connection. Nothing
    # that connection does after the failure (the write at its drop) may move
    # the last good time past it.
    test "a row write that fails closes the connection and leaves the last good time where " <>
           "it was written",
         ctx do
      last_good = DateTime.add(@now, -3_600, :second)
      seed_last_good(ctx, last_good)
      {pid, first} = start_stream(ctx)
      {_url, socket, _opts} = connect(pid, first)
      frame(pid, socket, [tick("t-4103")])

      exec!(
        ctx.conn,
        "CREATE TRIGGER cue_good_fails BEFORE UPDATE OF last_good_at ON cue_sources " <>
          "BEGIN SELECT RAISE(ABORT, 'disk full'); END",
        []
      )

      advance(ctx, 5)
      ExUnit.CaptureLog.capture_log(fn -> flush(pid) end)
      assert_receive {:closed, ^socket}
      scheduled(:connect, 1_000)
      exec!(ctx.conn, "DROP TRIGGER cue_good_fails", [])

      assert_same_time(source_row(ctx).last_good_at, last_good)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, reason: :ingest_failed}}
    end

    test "a store that does not answer closes the connection, which is dialled again, and the " <>
           "worker runs on",
         ctx do
      stalling = start_supervised!({TouchStallingRepo, forward_to: ctx.repo})
      # Forwarded requests share this budget, so it leaves room for a slow but
      # answering Repo; only the stalled write spends all of it.
      {pid, first} = start_stream(ctx, %{}, repo: stalling, repo_timeout_ms: 1_000)
      {_url, socket, _opts} = connect(pid, first)

      ExUnit.CaptureLog.capture_log(fn ->
        frame(pid, socket, [tick("t-5001")])
        flush(pid)
      end)

      assert_receive {:closed, ^socket}
      assert {_url, _socket, _opts} = dial(pid, scheduled(:connect, 1_000))
      assert Process.alive?(pid)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, reason: :ingest_failed}}
    end

    test "a clean stop writes what was counted since the last flush", ctx do
      {pid, first} = start_stream(ctx)
      {_url, socket, _opts} = connect(pid, first)
      frame(pid, socket, [tick("t-6001"), tick("t-6002", "QZRX")])

      :ok = stop_supervised(Stream)
      assert counts(ctx) == %{"received" => 2, "unmatched" => 1}
    end

    # The Repo budget here is past the supervisor's 5 s shutdown, so only the
    # clean stop's own bound lets it end before the kill.
    test "a clean stop whose counts the store does not take ends before its shutdown runs out",
         ctx do
      stalled =
        start_supervised!(
          {FermixTestSupport.StalledRepo, forward_to: ctx.repo, stall: [:counts_put]}
        )

      {pid, first} = start_stream(ctx, %{}, repo: stalled, repo_timeout_ms: @wait_ms)
      {_url, socket, _opts} = connect(pid, first)
      frame(pid, socket, [tick("t-6101")])
      ref = Process.monitor(pid)

      ExUnit.CaptureLog.capture_log(fn -> :ok = stop_supervised(Stream) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    end
  end

  # --- liveness --------------------------------------------------------------------

  describe "liveness" do
    test "a pong moves the last good time the flush writes, and the heartbeat pings again",
         ctx do
      {pid, first} = start_stream(ctx)
      {_url, socket, _opts} = connect(pid, first)
      heartbeat = scheduled(:heartbeat, 30_000)

      advance(ctx, 20)
      deliver(pid, {:cue_stream, socket, :pong})
      advance(ctx, 10)
      deliver(pid, heartbeat)

      assert_receive {:pinged, ^socket}
      scheduled(:heartbeat, 30_000)
      flush(pid)
      assert_same_time(source_row(ctx).last_good_at, DateTime.add(@now, 20, :second))
    end

    test "a connection silent past 90 seconds is closed and redialled", ctx do
      {pid, first} = start_stream(ctx)
      {_url, socket, _opts} = connect(pid, first)
      heartbeat = scheduled(:heartbeat, 30_000)

      advance(ctx, 100)
      deliver(pid, heartbeat)

      assert_receive {:closed, ^socket}
      scheduled(:connect, 1_000)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, reason: :stalled}}
    end
  end

  # --- notices -----------------------------------------------------------------------

  describe "notices" do
    test "a rejected credential stops the worker with an auth_failed notice", ctx do
      ref = ctx.ref
      {pid, first} = start_stream(ctx)
      monitor = Process.monitor(pid)
      {_url, socket, _opts} = dial(pid, first)

      send(socket, {:die, {:upgrade_refused, 401}})

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
      assert_received {:notice, ^ref, :auth_failed, _data}
      assert source_row(ctx).status == "auth_failed"
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :auth_failure}}
    end

    test "a stream down for 15 minutes tells the owner once per outage", ctx do
      ref = ctx.ref
      {pid, first} = start_stream(ctx)

      {_url, socket, _opts} = dial(pid, first)
      send(socket, {:die, {:connect_failed, :econnrefused}})
      down_check = scheduled(:down, 900_000)
      reconnect = scheduled(:connect, 1_000)

      advance(ctx, 901)
      deliver(pid, down_check)
      assert_received {:notice, ^ref, :down, data}
      assert data == %{since: DateTime.to_iso8601(@now)}

      # Once per outage: a failed redial does not tell the owner again.
      {_url, socket, _opts} = dial(pid, reconnect)
      send(socket, {:die, {:remote_closed, 1000}})
      scheduled(:connect, 2_000)
      refute_received {:scheduled, {:timer, :down, _token}, _ms}
      refute_received {:notice, ^ref, :down, _data}
    end

    test "the daily budget counts matched items; past it the stream closes until the next " <>
           "UTC day, the row says so, and the owner is told once",
         ctx do
      ref = ctx.ref
      set_clock(ctx, ~U[2026-10-12 18:00:00Z])
      {pid, first} = start_stream(ctx, %{"daily_budget" => 1})
      {_url, socket, _opts} = connect(pid, first)

      frame(pid, socket, [tick("t-4104", "QZRX"), tick("t-4105"), tick("t-4106")])

      assert offered(ctx) == [{"t-4105", [ctx.watcher]}]
      assert_receive {:closed, ^socket}
      assert_received {:notice, ^ref, :budget_reached, _data}
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :budget}}
      assert %{status: "over_budget", items_today: 1, items_day: "2026-10-12"} = source_row(ctx)
      scheduled(:connect, 6 * 3_600_000 + 1_000)

      flush(pid)
      assert %{"over_budget" => 1, "unmatched" => 1, "received" => 3} = counts(ctx)
    end
  end
end
