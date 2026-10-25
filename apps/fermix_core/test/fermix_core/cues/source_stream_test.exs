defmodule FermixCore.Cues.Source.StreamTest do
  # What every stream does, whatever its service sends: connecting, accepting,
  # liveness, the budget and the notices. One worker per test on its own temp
  # Repo, with a stand-in transport the test drives by hand (FakeCueTransport;
  # the worker's messages from a socket are crafted here), a hand-driven clock
  # and captured timers: no network, no real time. The source is a stream that
  # signs in with nothing, so no secret is read; signing in, reading frames and
  # the service's errors have their own file.
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Source.Stream
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.FakeCueTransport
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-12 14:00:00Z]
  @url "wss://quotes.example.net/live"
  @wait_ms 10_000

  setup do
    ctx = start_repo("stream")
    ref = "quotes-#{System.unique_integer([:positive])}"
    clock = start_supervised!({Agent, fn -> @now end}, id: :clock)

    TelemetryCapture.attach([[:fermix, :cue, :source], [:fermix, :cue, :lifecycle]],
      source_ref: ref
    )

    Map.merge(ctx, %{ref: ref, clock: clock})
  end

  # --- helpers ---------------------------------------------------------------

  # Resolved from a config section as the daemon resolves it.
  defp source(ctx, overrides) do
    section = Map.merge(%{"kind" => "stream", "url" => @url, "id_path" => "id"}, overrides)
    cues = Config.normalize(%{"sources" => %{ctx.ref => section}})
    {:ok, source} = Config.source(ctx.ref, cues)
    source
  end

  defp start_stream(ctx, overrides \\ %{}) do
    test = self()

    opts = [
      source: source(ctx, overrides),
      repo: ctx.repo,
      clock: fn -> Agent.get(ctx.clock, & &1) end,
      monotonic_ms: fn -> 0 end,
      schedule: fn message, ms -> send(test, {:scheduled, message, ms}) end,
      transport: FakeCueTransport,
      transport_opts: [test: test],
      admit: fn ref, n, _now_ms -> send(test, {:admit, ref, n}) && n end,
      notify: fn ref, kind, data, _opts -> send(test, {:notice, ref, kind, data}) && :sent end
    ]

    pid = start_supervised!({Stream, opts})
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

  defp tick(id), do: %{"id" => id, "symbol" => "HGFT", "price" => "41.20"}

  defp frame(pid, socket, messages),
    do: deliver(pid, {:cue_stream, socket, {:frame, {:text, Jason.encode!(messages)}}})

  defp flush(pid), do: deliver(pid, scheduled(:flush, 250))

  defp cue_ids(ctx) do
    ctx.conn
    |> rows("SELECT item_id FROM cues WHERE source_ref = ? ORDER BY id", [ctx.ref])
    |> List.flatten()
  end

  defp source_row(ctx) do
    {:ok, row} = Repo.cues_call(CuesSql, {:get_source, ctx.ref}, server: ctx.repo)
    row
  end

  defp gaps(ctx) do
    {:ok, gaps} = Repo.cues_call(CuesSql, {:list_gaps, %{source_ref: ctx.ref}}, server: ctx.repo)
    Map.new(gaps, &{&1.reason, &1})
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

  # --- connecting and accepting ------------------------------------------------------

  describe "connecting and accepting" do
    test "the first item proves the connection healthy and a flush writes it with the last " <>
           "good time and no cursor; the connection after a drop traces reconnect, and a " <>
           "repeat is a duplicate",
         ctx do
      ref = ctx.ref
      {pid, first} = start_stream(ctx)

      # A stream that signs in with nothing sends nothing on the upgrade.
      {url, socket, opts} = connect(pid, first)
      assert url == @url
      assert opts[:headers] == []
      assert opts[:messages] == []
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :connect}}

      frame(pid, socket, [tick("t-4101")])
      assert source_row(ctx).status == "connected"
      flush(pid)
      assert cue_ids(ctx) == ["t-4101"]
      assert_received {:admit, ^ref, 1}
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

      frame(pid, socket, [tick("t-4101"), tick("t-4102")])
      flush(pid)

      assert cue_ids(ctx) == ["t-4101", "t-4102"]
      assert_received {:telemetry, [:fermix, :cue, :lifecycle], _m, %{phase: :duplicate}}
      assert source_row(ctx).cursor == nil
      assert gaps(ctx) == %{}
    end

    # A batch that fails to commit closes the connection. Nothing that
    # connection does after the failure (the flush at its drop) may move the
    # last good time past items that were never stored.
    test "a batch that fails to commit leaves the last good time where it was committed", ctx do
      last_good = DateTime.add(@now, -3_600, :second)
      seed_last_good(ctx, last_good)
      {pid, first} = start_stream(ctx)
      {_url, socket, _opts} = connect(pid, first)

      exec!(
        ctx.conn,
        "CREATE TRIGGER cue_insert_fails BEFORE INSERT ON cues " <>
          "BEGIN SELECT RAISE(ABORT, 'disk full'); END",
        []
      )

      frame(pid, socket, [tick("t-4103")])
      advance(ctx, 5)
      ExUnit.CaptureLog.capture_log(fn -> flush(pid) end)
      assert_receive {:closed, ^socket}
      exec!(ctx.conn, "DROP TRIGGER cue_insert_fails", [])

      scheduled(:connect, 1_000)
      assert cue_ids(ctx) == []
      assert_same_time(source_row(ctx).last_good_at, last_good)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, reason: :ingest_failed}}
    end
  end

  # --- liveness --------------------------------------------------------------------

  describe "liveness" do
    test "a pong moves the last good time and the heartbeat pings again", ctx do
      {pid, first} = start_stream(ctx)
      {_url, socket, _opts} = connect(pid, first)
      heartbeat = scheduled(:heartbeat, 30_000)

      advance(ctx, 20)
      deliver(pid, {:cue_stream, socket, :pong})
      advance(ctx, 10)
      deliver(pid, heartbeat)

      assert_receive {:pinged, ^socket}
      assert_same_time(source_row(ctx).last_good_at, DateTime.add(@now, 20, :second))
      scheduled(:heartbeat, 30_000)
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

    test "the daily budget closes the stream until the next UTC day and tells the owner once",
         ctx do
      ref = ctx.ref
      set_clock(ctx, ~U[2026-10-12 18:00:00Z])
      {pid, first} = start_stream(ctx, %{"daily_budget" => 1})
      {_url, socket, _opts} = connect(pid, first)

      frame(pid, socket, [tick("t-4104"), tick("t-4105")])
      flush(pid)

      assert length(cue_ids(ctx)) == 1
      assert_receive {:closed, ^socket}
      assert_received {:notice, ^ref, :budget_reached, _data}
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :budget}}
      assert source_row(ctx).status == "over_budget"
      scheduled(:connect, 6 * 3_600_000 + 1_000)
    end
  end
end
