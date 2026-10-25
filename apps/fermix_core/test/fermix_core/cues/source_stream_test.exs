defmodule FermixCore.Cues.Source.StreamTest do
  # One worker per test on its own temp Repo, with a stand-in transport the test
  # drives by hand (FakeCueTransport; the worker's messages from a socket are
  # crafted here), a hand-driven clock and captured timers: no network, no real
  # time. The general source, a stream with no preset, has its own file.
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Source.Stream
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.FakeCueTransport
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-12 14:00:00Z]
  @author "did:plc:k4tmw2qzr7bnvx3e5hjy6dfa"
  @friend "did:plc:p2nrd7wq4fxk6jzv3mbt5hce"
  @stranger "did:plc:zz7xq4m2rbw6n3kd5tyhvjpa"
  @wait_ms 10_000

  setup do
    ctx = start_repo("stream")
    ref = "bsky-#{System.unique_integer([:positive])}"
    clock = start_supervised!({Agent, fn -> @now end}, id: :clock)

    TelemetryCapture.attach([[:fermix, :cue, :source], [:fermix, :cue, :lifecycle]],
      source_ref: ref
    )

    Map.merge(ctx, %{ref: ref, clock: clock})
  end

  # --- helpers ---------------------------------------------------------------

  defp source(ctx, overrides) do
    Map.merge(
      %{
        ref: ctx.ref,
        kind: :stream,
        preset: "bluesky_jetstream",
        enabled?: true,
        daily_budget: 0,
        url: "wss://jetstream.us-east.bsky.network",
        dids: [@author, @friend],
        collections: ["app.bsky.feed.post"],
        secrets: %{}
      },
      overrides
    )
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
    assert_receive {:dialed, url, socket, _opts}
    {url, socket}
  end

  defp connect(pid, message) do
    {url, socket} = dial(pid, message)
    deliver(pid, {:cue_stream, socket, :connected})
    {url, socket}
  end

  defp set_clock(ctx, at), do: Agent.update(ctx.clock, fn _old -> at end)

  defp advance(ctx, seconds), do: Agent.update(ctx.clock, &DateTime.add(&1, seconds, :second))

  defp cursor(url),
    do:
      url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.query_decoder()
      |> Map.new()
      |> Map.get("cursor")

  defp us(datetime), do: DateTime.to_unix(datetime, :microsecond)

  defp post(did, rkey, at, operation \\ "create") do
    Jason.encode!(%{
      "$type" => "message",
      "payload" => %{
        "$type" => "network.bsky.jetstream.subscribeEvents#commit",
        "seq" => 48_210_375,
        "did" => did,
        "time" => DateTime.to_iso8601(at),
        "operation" => operation,
        "collection" => "app.bsky.feed.post",
        "rkey" => rkey,
        "cid" => "bafyreihk3tq5xw7pjz2m4cv6nbd7r2ylqgfo5ae3kxu4wsnh6tjm2vpzie",
        "record" => %{
          "$type" => "app.bsky.feed.post",
          "text" => "Post #{rkey}",
          "createdAt" => DateTime.to_iso8601(at)
        }
      }
    })
  end

  defp frame(pid, socket, text), do: deliver(pid, {:cue_stream, socket, {:frame, {:text, text}}})

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

  defp uri(did, rkey), do: "at://#{did}/app.bsky.feed.post/#{rkey}"

  # --- C03 / C47 -----------------------------------------------------------------

  describe "C03/C47: the bluesky_jetstream source" do
    test "a two-minute disconnect reconnects with the cursor rewound by five minutes and " <>
           "accepts what it missed; a repeat is a duplicate; a stranger's post is not accepted",
         ctx do
      ref = ctx.ref
      {pid, first} = start_stream(ctx)

      # A new source starts at the live tip.
      {url, socket} = connect(pid, first)
      assert cursor(url) == nil
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :connect}}

      # The first item proves the connection healthy: the row says connected.
      frame(pid, socket, post(@author, "3m4qa", DateTime.add(@now, -1, :second)))
      assert source_row(ctx).status == "connected"
      flush(pid)
      assert cue_ids(ctx) == [uri(@author, "3m4qa")]
      assert_received {:admit, ^ref, 1}
      row = source_row(ctx)
      assert_same_time(row.last_good_at, @now)
      assert row.cursor == Integer.to_string(us(DateTime.add(@now, -1, :second)))

      # The connection drops 30 s later, and comes back two minutes after that.
      advance(ctx, 30)
      send(socket, {:die, {:remote_closed, 1000}})
      reconnect = scheduled(:connect, 1_000)
      assert source_row(ctx).status == "reconnecting"

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, attempt: 1}}

      advance(ctx, 120)
      {url, socket} = connect(pid, reconnect)
      assert cursor(url) == Integer.to_string(us(DateTime.add(@now, -300, :second)))
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :reconnect}}
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :backfill}}

      # The rewind replays the post already accepted, then the one missed, then a
      # post by an account the source does not follow.
      frame(pid, socket, post(@author, "3m4qa", DateTime.add(@now, -1, :second)))
      frame(pid, socket, post(@friend, "3m4qb", DateTime.add(@now, 60, :second)))
      frame(pid, socket, post(@stranger, "3m4qc", DateTime.add(@now, 70, :second)))
      flush(pid)

      assert cue_ids(ctx) == [uri(@author, "3m4qa"), uri(@friend, "3m4qb")]
      assert_received {:telemetry, [:fermix, :cue, :lifecycle], _m, %{phase: :duplicate}}
      assert gaps(ctx) == %{}
    end

    test "a disconnect longer than 24 hours reaches back 24 hours and records the rest as a gap",
         ctx do
      last_good = DateTime.add(@now, -30 * 3_600, :second)
      seed_last_good(ctx, last_good)
      {pid, first} = start_stream(ctx)

      {url, _socket} = connect(pid, first)

      floor = DateTime.add(@now, -24 * 3_600, :second)
      assert cursor(url) == Integer.to_string(us(floor))
      assert %{"disconnect" => gap} = gaps(ctx)
      assert gap.range_from == CuesSql.stamp(DateTime.add(last_good, -300, :second))
      assert gap.range_to == CuesSql.stamp(floor)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :gap, reason: "disconnect"}}
    end

    test "a drop in the middle of a backfill resumes where the replay got to", ctx do
      seed_last_good(ctx, DateTime.add(@now, -3_600, :second))
      {pid, first} = start_stream(ctx)
      {url, socket} = connect(pid, first)
      assert cursor(url) == Integer.to_string(us(DateTime.add(@now, -3_900, :second)))

      replayed = DateTime.add(@now, -3_000, :second)
      frame(pid, socket, post(@author, "3m4qf", replayed))
      flush(pid)
      assert_same_time(source_row(ctx).last_good_at, replayed)

      advance(ctx, 5)
      send(socket, {:die, {:remote_closed, 1000}})
      reconnect = scheduled(:connect, 1_000)
      {url, _socket} = dial(pid, reconnect)
      assert cursor(url) == Integer.to_string(us(DateTime.add(replayed, -300, :second)))
    end

    # A batch that fails to commit closes the connection, and the next one
    # rewinds from the last good time committed, so the batch comes again.
    # Nothing that connection does after the failure (the flush at its drop)
    # may move that time past items that were never stored.
    test "a batch that fails to commit is replayed from the last good time committed", ctx do
      last_good = DateTime.add(@now, -3_600, :second)
      seed_last_good(ctx, last_good)
      {pid, first} = start_stream(ctx)
      {_url, socket} = connect(pid, first)

      exec!(
        ctx.conn,
        "CREATE TRIGGER cue_insert_fails BEFORE INSERT ON cues " <>
          "BEGIN SELECT RAISE(ABORT, 'disk full'); END",
        []
      )

      lost = DateTime.add(@now, -3_000, :second)
      frame(pid, socket, post(@author, "3m4qg", lost))
      advance(ctx, 5)
      ExUnit.CaptureLog.capture_log(fn -> flush(pid) end)
      assert_receive {:closed, ^socket}
      exec!(ctx.conn, "DROP TRIGGER cue_insert_fails", [])

      reconnect = scheduled(:connect, 1_000)
      assert cue_ids(ctx) == []
      assert_same_time(source_row(ctx).last_good_at, last_good)

      {url, socket} = connect(pid, reconnect)
      assert cursor(url) == Integer.to_string(us(DateTime.add(last_good, -300, :second)))

      frame(pid, socket, post(@author, "3m4qg", lost))
      flush(pid)
      assert cue_ids(ctx) == [uri(@author, "3m4qg")]
    end

    test "a backfill with nothing to replay ends at the first quiet heartbeat", ctx do
      seed_last_good(ctx, DateTime.add(@now, -600, :second))
      {pid, first} = start_stream(ctx)
      {_url, socket} = connect(pid, first)
      heartbeat = scheduled(:heartbeat, 30_000)

      advance(ctx, 20)
      deliver(pid, {:cue_stream, socket, :pong})
      advance(ctx, 10)
      deliver(pid, heartbeat)

      assert_same_time(source_row(ctx).last_good_at, DateTime.add(@now, 20, :second))
    end

    test "a resume point the service clamped is recorded as a gap", ctx do
      seed_last_good(ctx, DateTime.add(@now, -600, :second))
      {pid, first} = start_stream(ctx)
      {_url, socket} = connect(pid, first)

      info =
        Jason.encode!(%{
          "$type" => "message",
          "payload" => %{
            "$type" => "network.bsky.jetstream.subscribeEvents#info",
            "name" => "OutdatedCursor"
          }
        })

      frame(pid, socket, info)
      assert %{"disconnect" => %{count: 1}} = gaps(ctx)
    end
  end

  # --- C40 -------------------------------------------------------------------------

  describe "C40: the frame cap" do
    test "a 200 KiB frame closes the connection with a read_limit gap, and the next " <>
           "connection resumes after it",
         ctx do
      {pid, first} = start_stream(ctx)
      {_url, socket} = connect(pid, first)

      frame(pid, socket, String.duplicate("x", 200 * 1024))

      assert_receive {:closed, ^socket}
      assert %{"read_limit" => %{count: 1}} = gaps(ctx)
      reconnect = scheduled(:connect, 1_000)

      advance(ctx, 1)
      {url, _socket} = dial(pid, reconnect)
      assert cursor(url) == Integer.to_string(us(@now))
    end

    test "the transport is given the 128 KiB cap, and a connection it ends at a larger frame " <>
           "takes the same path",
         ctx do
      {pid, first} = start_stream(ctx)
      deliver(pid, first)
      assert_receive {:dialed, _url, socket, opts}
      assert opts[:max_frame_bytes] == 128 * 1024
      assert opts[:headers] == []
      deliver(pid, {:cue_stream, socket, :connected})

      send(socket, {:die, :frame_too_large})

      reconnect = scheduled(:connect, 1_000)
      assert %{"read_limit" => %{count: 1}} = gaps(ctx)
      advance(ctx, 1)
      {url, _socket} = dial(pid, reconnect)
      assert cursor(url) == Integer.to_string(us(@now))
    end
  end

  # --- liveness --------------------------------------------------------------------

  describe "liveness" do
    test "a pong moves the last good time and the heartbeat pings again", ctx do
      {pid, first} = start_stream(ctx)
      {_url, socket} = connect(pid, first)
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
      {_url, socket} = connect(pid, first)
      heartbeat = scheduled(:heartbeat, 30_000)

      advance(ctx, 100)
      deliver(pid, heartbeat)

      assert_receive {:closed, ^socket}
      scheduled(:connect, 1_000)
    end
  end

  # --- notices -----------------------------------------------------------------------

  describe "notices" do
    test "a rejected credential stops the worker with an auth_failed notice", ctx do
      ref = ctx.ref
      {pid, first} = start_stream(ctx)
      monitor = Process.monitor(pid)
      {_url, socket} = dial(pid, first)

      send(socket, {:die, {:upgrade_refused, 401}})

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
      assert_received {:notice, ^ref, :auth_failed, _data}
      assert source_row(ctx).status == "auth_failed"
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :auth_failure}}
    end

    test "a stream with nothing to replay that is down for 15 minutes tells the owner once " <>
           "per outage",
         ctx do
      ref = ctx.ref
      {pid, first} = start_stream(ctx)

      # It never connects, so it has no last good time to resume from.
      {_url, socket} = dial(pid, first)
      send(socket, {:die, {:connect_failed, :econnrefused}})
      down_check = scheduled(:down, 900_000)
      reconnect = scheduled(:connect, 1_000)

      advance(ctx, 901)
      deliver(pid, down_check)
      assert_received {:notice, ^ref, :down, _data}

      # Once per outage: a failed redial does not tell the owner again.
      {_url, socket} = dial(pid, reconnect)
      send(socket, {:die, {:remote_closed, 1000}})
      scheduled(:connect, 2_000)
      refute_received {:scheduled, {:timer, :down, _token}, _ms}
      refute_received {:notice, ^ref, :down, _data}
    end

    test "an outage a reconnect can still replay waits until the replay window is lost", ctx do
      ref = ctx.ref
      seed_last_good(ctx, DateTime.add(@now, -3_600, :second))
      {pid, first} = start_stream(ctx)
      {_url, socket} = connect(pid, first)

      send(socket, {:die, {:remote_closed, 1000}})

      # The resume point is an hour and five minutes back; 24 hours after it,
      # the rest is lost: 22 h 55 min from now.
      down_check = scheduled(:down, (22 * 3_600 + 55 * 60) * 1_000)
      deliver(pid, down_check)
      assert_received {:notice, ^ref, :down, _data}
    end

    test "the daily budget closes the stream until the next UTC day and tells the owner once",
         ctx do
      ref = ctx.ref
      set_clock(ctx, ~U[2026-10-12 18:00:00Z])
      {pid, first} = start_stream(ctx, %{daily_budget: 1})
      {_url, socket} = connect(pid, first)

      frame(pid, socket, post(@author, "3m4qd", ~U[2026-10-12 17:59:00Z]))
      frame(pid, socket, post(@friend, "3m4qe", ~U[2026-10-12 17:59:30Z]))
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
