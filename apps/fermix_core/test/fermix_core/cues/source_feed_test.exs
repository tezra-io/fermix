defmodule FermixCore.Cues.Source.FeedTest do
  # One worker per test on its own temp Repo, with an in-process HTTP stub
  # (`plug:`), a fixed resolver and a hand-driven clock and timers: no network,
  # no DNS, no real time.
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Source.Feed
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-10 12:00:00Z]
  @url "https://feeds.example.test/releases.xml"
  @public_ip {93, 184, 216, 34}
  @interval_s 300
  @wait_ms 10_000

  setup do
    ctx = start_repo("feed")
    ref = "feed-#{System.unique_integer([:positive])}"
    clock = start_supervised!({Agent, fn -> @now end}, id: :clock)

    server =
      start_supervised!({Agent, fn -> feed([{"a", "First", hours_ago(1)}], "v1") end},
        id: :server
      )

    TelemetryCapture.attach([[:fermix, :cue, :source]], source_ref: ref)
    Map.merge(ctx, %{ref: ref, clock: clock, server: server})
  end

  # --- helpers ---------------------------------------------------------------

  defp hours_ago(hours), do: DateTime.add(@now, -hours * 3_600, :second)

  defp rss(items) do
    entries =
      Enum.map_join(items, "", fn {guid, title, date} ->
        pub =
          if date,
            do: "<pubDate>#{Calendar.strftime(date, "%a, %d %b %Y %H:%M:%S")} GMT</pubDate>"

        "<item><title>#{title}</title><link>https://releases.example.org/posts/#{guid}</link>" <>
          "<guid isPermaLink=\"false\">#{guid}</guid>#{pub}</item>"
      end)

    ~s(<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel>) <>
      "<title>Larkspur Tools Releases</title><link>https://releases.example.org/</link>" <>
      "<description>Release notes.</description>#{entries}</channel></rss>"
  end

  defp feed(items, etag),
    do: %{status: 200, body: rss(items), etag: etag, headers: [], conditional?: true}

  defp serve(ctx, reply), do: Agent.update(ctx.server, fn _old -> reply end)

  defp set_clock(ctx, at), do: Agent.update(ctx.clock, fn _old -> at end)

  defp plug(server, test) do
    fn conn ->
      send(test, {:request, conn.host, Plug.Conn.get_req_header(conn, "if-none-match")})
      reply(conn, Agent.get(server, & &1))
    end
  end

  defp reply(conn, %{conditional?: true, etag: etag} = reply) when is_binary(etag) do
    if Plug.Conn.get_req_header(conn, "if-none-match") == [etag],
      do: Plug.Conn.send_resp(conn, 304, ""),
      else: send_reply(conn, reply)
  end

  defp reply(conn, reply), do: send_reply(conn, reply)

  defp send_reply(conn, reply) do
    headers = [{"content-type", "application/rss+xml"}, {"etag", reply.etag} | reply.headers]

    headers
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Enum.reduce(conn, fn {name, value}, acc -> Plug.Conn.put_resp_header(acc, name, value) end)
    |> Plug.Conn.send_resp(reply.status, reply.body)
  end

  defp source(ctx, overrides) do
    Map.merge(
      %{
        ref: ctx.ref,
        kind: :feed,
        preset: "rss",
        enabled?: true,
        daily_budget: 0,
        url: @url,
        interval: @interval_s,
        items_path: nil,
        id_path: nil,
        revision_path: nil,
        type_path: nil,
        subject_path: nil,
        time_path: nil,
        secrets: %{}
      },
      overrides
    )
  end

  defp start_feed(ctx, overrides \\ %{}) do
    test = self()

    opts = [
      source: source(ctx, overrides),
      repo: ctx.repo,
      clock: fn -> Agent.get(ctx.clock, & &1) end,
      monotonic_ms: fn -> 0 end,
      schedule: fn message, ms -> send(test, {:scheduled, message, ms}) end,
      req_options: [plug: plug(ctx.server, test)],
      resolver: fn _host -> {:ok, [@public_ip]} end,
      admit: fn ref, n, _now_ms -> send(test, {:admit, ref, n}) && n end,
      notify: fn ref, kind, data, _opts -> send(test, {:notice, ref, kind, data}) && :sent end
    ]

    pid = start_supervised!({Feed, opts})
    {pid, next_poll()}
  end

  defp next_poll(expected_ms \\ nil) do
    assert_receive {:scheduled, {:timer, :poll, _token} = message, ms}
    if expected_ms, do: assert(ms == expected_ms)
    message
  end

  # Delivers a timer by hand and waits until the worker handled it.
  defp fire(pid, message) do
    send(pid, message)
    _state = :sys.get_state(pid)
    :ok
  end

  defp cue_ids(ctx) do
    ctx.conn
    |> rows("SELECT item_id FROM cues WHERE source_ref = ? ORDER BY item_id", [ctx.ref])
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

  defp poll_every_interval, do: next_poll(@interval_s * 1_000)

  # --- C04 ---------------------------------------------------------------------

  describe "C04: conditional polls" do
    test "an unchanged feed answers 304 and makes no cue; two new items make two cues, none twice",
         ctx do
      {pid, first} = start_feed(ctx)
      fire(pid, first)

      assert_received {:request, "feeds.example.test", []}
      assert cue_ids(ctx) == ["a"]
      row = source_row(ctx)
      assert row.status == "polling"
      assert DateTime.compare(row.last_good_at, @now) == :eq
      assert Jason.decode!(row.cursor) == %{"etag" => "v1"}
      assert_received {:telemetry, [:fermix, :cue, :source], _measurements, %{phase: :connect}}

      # Unchanged: the stored ETag goes out and the 304 stores nothing new.
      fire(pid, poll_every_interval())
      assert_received {:request, "feeds.example.test", ["v1"]}
      assert cue_ids(ctx) == ["a"]

      # Two new items.
      serve(
        ctx,
        feed(
          [
            {"c", "Third", hours_ago(0)},
            {"b", "Second", hours_ago(0)},
            {"a", "First", hours_ago(1)}
          ],
          "v2"
        )
      )

      fire(pid, poll_every_interval())
      assert cue_ids(ctx) == ["a", "b", "c"]
      assert Jason.decode!(source_row(ctx).cursor) == %{"etag" => "v2"}

      # The same page again, from a server that ignores the ETag: all duplicates.
      serve(ctx, %{
        feed(
          [
            {"c", "Third", hours_ago(0)},
            {"b", "Second", hours_ago(0)},
            {"a", "First", hours_ago(1)}
          ],
          "v3"
        )
        | conditional?: false
      })

      fire(pid, poll_every_interval())
      assert cue_ids(ctx) == ["a", "b", "c"]
      assert Process.alive?(pid)
    end

    test "a gzip-encoded feed is read after decompression", ctx do
      body = :zlib.gzip(rss([{"z", "Zipped", hours_ago(1)}]))

      serve(ctx, %{
        status: 200,
        body: body,
        etag: "gz1",
        headers: [{"content-encoding", "gzip"}],
        conditional?: true
      })

      {pid, first} = start_feed(ctx)
      fire(pid, first)

      assert cue_ids(ctx) == ["z"]
    end

    test "the source's rate bucket is asked before the items are accepted", ctx do
      ref = ctx.ref
      {pid, first} = start_feed(ctx)
      fire(pid, first)

      assert_received {:admit, ^ref, 1}
    end
  end

  # --- C40 ---------------------------------------------------------------------

  describe "C40: limits on what a feed reads" do
    test "a response over 4 MiB is closed with a read_limit gap and no cue", ctx do
      body = String.duplicate("x", 4 * 1024 * 1024 + 1)
      serve(ctx, %{status: 200, body: body, etag: "big", headers: [], conditional?: true})

      {pid, first} = start_feed(ctx)
      fire(pid, first)

      assert cue_ids(ctx) == []
      assert %{"read_limit" => %{count: 1}} = gaps(ctx)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :gap, reason: "read_limit"}}

      # Not a failure: the next poll comes at the interval.
      poll_every_interval()
    end

    test "a gzip body that inflates past 4 MiB is a read_limit gap too", ctx do
      body = :zlib.gzip(String.duplicate(" ", 5 * 1024 * 1024))

      serve(ctx, %{
        status: 200,
        body: body,
        etag: "bomb",
        headers: [{"content-encoding", "gzip"}],
        conditional?: true
      })

      {pid, first} = start_feed(ctx)
      fire(pid, first)

      assert cue_ids(ctx) == []
      assert %{"read_limit" => %{count: 1}} = gaps(ctx)
    end

    test "a 1,000-item page accepts 100 and records the rest as a page_limit gap with its range",
         ctx do
      items =
        for n <- 1..1_000, do: {"item-#{n}", "Item #{n}", DateTime.add(@now, -n * 60, :second)}

      serve(ctx, feed(items, "many"))

      {pid, first} = start_feed(ctx)
      fire(pid, first)

      assert length(cue_ids(ctx)) == 100
      assert %{"page_limit" => gap} = gaps(ctx)
      assert gap.count == 900
      assert gap.range_from == CuesSql.stamp(DateTime.add(@now, -1_000 * 60, :second))
      assert gap.range_to == CuesSql.stamp(DateTime.add(@now, -101 * 60, :second))
    end

    test "a redirect to 169.254.169.254 is refused before any request reaches it", ctx do
      serve(ctx, %{
        status: 302,
        body: "",
        etag: nil,
        headers: [{"location", "https://169.254.169.254/latest/meta-data/"}],
        conditional?: false
      })

      {pid, first} = start_feed(ctx)
      fire(pid, first)

      assert_received {:request, "feeds.example.test", []}
      refute_received {:request, "169.254.169.254", _etag}
      assert cue_ids(ctx) == []

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, attempt: 1, error_class: "blocked"}}

      # A failed poll backs off: the first retry comes after a minute.
      next_poll(60_000)
    end

    test "more than three redirects are refused", ctx do
      serve(ctx, %{
        status: 301,
        body: "",
        etag: nil,
        headers: [{"location", @url}],
        conditional?: false
      })

      {pid, first} = start_feed(ctx)
      fire(pid, first)

      for _hop <- 1..4, do: assert_received({:request, "feeds.example.test", []})
      refute_received {:request, _host, _etag}

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, error_class: "too_many_redirects"}}
    end
  end

  # --- receipt-only ------------------------------------------------------------

  describe "undated items on the first poll" do
    test "are receipts with no delivery; on a later poll an undated item is routed", ctx do
      watcher = insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})
      serve(ctx, feed([{"undated", "No date", nil}, {"dated", "Dated", hours_ago(1)}], "v1"))

      {pid, first} = start_feed(ctx)
      fire(pid, first)

      assert cue_ids(ctx) == ["dated", "undated"]
      assert delivered(ctx, watcher) == ["dated"]

      serve(ctx, feed([{"undated-2", "Later, no date", nil}, {"undated", "No date", nil}], "v2"))
      fire(pid, poll_every_interval())

      assert delivered(ctx, watcher) == ["dated", "undated-2"]
    end
  end

  defp delivered(ctx, watcher) do
    ctx.conn
    |> rows(
      "SELECT c.item_id FROM cue_deliveries d JOIN cues c ON c.id = d.cue_id " <>
        "WHERE d.watcher_id = ? ORDER BY c.item_id",
      [watcher]
    )
    |> List.flatten()
  end

  # --- failures ----------------------------------------------------------------

  describe "a feed that keeps failing" do
    test "backs off, doubling from a minute, and stops itself with a notice", ctx do
      ref = ctx.ref
      serve(ctx, %{status: 503, body: "busy", etag: nil, headers: [], conditional?: false})

      {pid, first} = start_feed(ctx)
      monitor = Process.monitor(pid)
      fire(pid, first)

      for delay <- [60_000, 120_000, 240_000, 480_000, 960_000, 1_920_000] do
        fire(pid, next_poll(delay))
      end

      # The eighth failure in a row stops it.
      send(pid, next_poll(3_600_000))
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
      assert_received {:notice, ^ref, :unreachable, %{failures: 8}}
      assert source_row(ctx).status == "stopped"
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :stopped}}
    end

    test "a feed URL that is not https is refused at once and the worker stops", ctx do
      {pid, first} = start_feed(ctx, %{url: "http://feeds.example.test/releases.xml"})
      monitor = Process.monitor(pid)
      send(pid, first)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
      refute_received {:request, _host, _etag}
      assert source_row(ctx).status == "unavailable"
    end
  end

  # --- daily budget ----------------------------------------------------------------

  describe "the daily budget" do
    test "stops polling until the next UTC day and tells the owner once", ctx do
      ref = ctx.ref

      items = [
        {"c", "Third", hours_ago(0)},
        {"b", "Second", hours_ago(1)},
        {"a", "First", hours_ago(2)}
      ]

      serve(ctx, feed(items, "v1"))

      {pid, first} = start_feed(ctx, %{daily_budget: 2})
      fire(pid, first)

      assert length(cue_ids(ctx)) == 2
      assert source_row(ctx).status == "over_budget"
      assert_received {:notice, ^ref, :budget_reached, _data}
      assert_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :budget}}

      # Midnight UTC plus a second, from noon.
      until_tomorrow = next_poll(12 * 3_600_000 + 1_000)
      assert_received {:request, _host, _etag}

      # Fired early (the same day), it does not poll and waits again.
      fire(pid, until_tomorrow)
      refute_received {:request, _host, _etag}
      tomorrow = next_poll(12 * 3_600_000 + 1_000)

      set_clock(ctx, ~U[2026-10-11 00:00:01Z])
      fire(pid, tomorrow)
      assert_received {:request, "feeds.example.test", _etag}
      refute_received {:notice, ^ref, :budget_reached, _data}
    end
  end
end
