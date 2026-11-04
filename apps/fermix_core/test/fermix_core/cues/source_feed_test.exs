defmodule FermixCore.Cues.Source.FeedTest do
  # One worker per test on its own temp Repo, with an in-process HTTP stub
  # (`plug:`), a fixed resolver and a hand-driven clock and timers: no network,
  # no DNS, no real time.
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Source.Feed
  alias FermixCore.Cues.XAccounts
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Net.Egress
  alias FermixCore.Plugins.Plugin
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-10 12:00:00Z]
  @url "https://feeds.example.test/releases.xml"
  @public_ip {93, 184, 216, 34}
  @other_public_ip {93, 184, 216, 35}
  @interval_s 300
  @wait_ms 10_000

  # A Repo in front of the test's own that takes the accept transaction and
  # never answers it, and forwards every other request: the store held up
  # behind a long write, as the poll sees it.
  defmodule AcceptStallingRepo do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def handle_call({:cues, CuesSql, {:accept, _source, _items, _now, _state}}, _from, state),
      do: {:noreply, state}

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.forward_to, request), state}
  end

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
      send(test, {:request, host_seen(conn), Plug.Conn.get_req_header(conn, "if-none-match")})
      reply(conn, Agent.get(server, & &1))
    end
  end

  # The host a server is asked for: the `Host` a pinned request carries (its
  # URL holds the checked address), else the URL's own, as Mint would send it.
  defp host_seen(conn), do: conn |> Plug.Conn.get_req_header("host") |> List.first(conn.host)

  # An origin seen at the adapter, after `Net.Egress` routed the hop, so a test
  # reads what a real dial would use: the URL's host (the address dialled), the
  # host asked for, the TLS name, the path and the proxy, if any.
  defp origin(test, answer) do
    fn request ->
      connect = request.options[:connect_options] || []
      name = request |> Req.Request.get_header("host") |> List.first(request.url.host)
      sni = connect[:transport_opts][:server_name_indication]
      send(test, {:dialled, request.url.host, name, sni, request.url.path, connect[:proxy]})
      {request, answer.(name, request.url.path)}
    end
  end

  defp feed_response(body),
    do:
      Req.Response.new(
        status: 200,
        headers: [{"content-type", "application/rss+xml"}],
        body: body
      )

  defp redirect_response(location),
    do: Req.Response.new(status: 302, headers: [{"location", location}])

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

  defp start_feed(ctx, overrides \\ %{}, worker_opts \\ []) do
    test = self()

    opts = [
      source: source(ctx, overrides),
      repo: ctx.repo,
      clock: fn -> Agent.get(ctx.clock, & &1) end,
      monotonic_ms: fn -> 0 end,
      schedule: fn message, ms -> send(test, {:scheduled, message, ms}) end,
      req_options: [plug: plug(ctx.server, test)],
      resolver: fn _host -> {:ok, [@public_ip]} end,
      egress: Egress.new([]),
      admit: fn ref, n, _now_ms -> send(test, {:admit, ref, n}) && n end,
      notify: fn ref, kind, data, _opts -> send(test, {:notice, ref, kind, data}) && :sent end
    ]

    pid = start_supervised!({Feed, Keyword.merge(opts, worker_opts)})
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
    test "a gzipped archive that unpacks past 4 MiB is read; its old items are no gap", ctx do
      notes = String.duplicate("Guests talk about tides, maps and long walks. ", 44)

      items =
        Enum.map_join(1..2_770, "", fn n ->
          published = Calendar.strftime(DateTime.add(@now, -n, :day), "%a, %d %b %Y %H:%M:%S")

          "<item><title>Episode #{n}</title><guid>episode-#{n}</guid>" <>
            "<pubDate>#{published} GMT</pubDate><description>#{notes}</description></item>"
        end)

      xml = ~s(<rss version="2.0"><channel><title>Harbour Hours</title>#{items}</channel></rss>)
      assert byte_size(xml) > 4 * 1024 * 1024

      serve(ctx, %{
        status: 200,
        body: :zlib.gzip(xml),
        etag: "archive",
        headers: [{"content-encoding", "gzip"}],
        conditional?: true
      })

      {pid, first} = start_feed(ctx)
      fire(pid, first)

      # The seven inside the receipt horizon become cues; the rest is skipped,
      # neither a stale reject nor a gap.
      assert cue_ids(ctx) == Enum.sort(Enum.map(1..7, &"episode-#{&1}"))
      assert gaps(ctx) == %{}
      row = source_row(ctx)
      assert row.status == "polling"
      assert row.reject_counts == %{}
      assert Jason.decode!(row.cursor) == %{"etag" => "archive"}

      assert_received {:telemetry, [:fermix, :cue, :source], %{skipped: 2_763},
                       %{phase: :connect}}
    end

    test "120 fresh and 50 stale items make 100 cues and a page_limit gap of 20, nothing stale",
         ctx do
      fresh = for n <- 1..120, do: {"fresh-#{n}", "Fresh #{n}", DateTime.add(@now, -n, :minute)}
      stale = for n <- 1..50, do: {"stale-#{n}", "Stale #{n}", DateTime.add(@now, -8 - n, :day)}
      serve(ctx, feed(stale ++ fresh, "mixed"))

      {pid, first} = start_feed(ctx)
      fire(pid, first)

      assert cue_ids(ctx) == Enum.sort(Enum.map(1..100, &"fresh-#{&1}"))
      assert %{"page_limit" => gap} = gaps(ctx)
      assert map_size(gaps(ctx)) == 1
      assert gap.count == 20
      assert gap.range_from == CuesSql.stamp(DateTime.add(@now, -120, :minute))
      assert gap.range_to == CuesSql.stamp(DateTime.add(@now, -101, :minute))
      assert source_row(ctx).reject_counts == %{}
    end

    test "a first read of stale and undated items keeps the undated as receipts, nothing stale",
         ctx do
      watcher = insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})
      items = [{"old", "Old", DateTime.add(@now, -30, :day)}, {"undated", "No date", nil}]
      serve(ctx, feed(items, "v1"))

      {pid, first} = start_feed(ctx)
      fire(pid, first)

      assert cue_ids(ctx) == ["undated"]
      assert delivered(ctx, watcher) == []
      assert gaps(ctx) == %{}
      assert source_row(ctx).reject_counts == %{}
    end

    test "a download over 16 MiB stops the source as unavailable with a notice and a gap", ctx do
      ref = ctx.ref
      body = String.duplicate("x", 16 * 1024 * 1024 + 1)
      serve(ctx, %{status: 200, body: body, etag: "big", headers: [], conditional?: true})

      {pid, first} = start_feed(ctx)
      monitor = Process.monitor(pid)
      send(pid, first)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
      assert cue_ids(ctx) == []
      assert %{"read_limit" => %{count: 1}} = gaps(ctx)
      assert %{status: "unavailable", stop_reason: "too_large"} = source_row(ctx)
      assert_received {:notice, ^ref, :too_large, %{}}

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :gap, reason: "read_limit"}}

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :stopped, status: "unavailable", reason: :read_limit}}
    end

    test "a gzip body that unpacks past the reader's limit stops it the same way", ctx do
      ref = ctx.ref
      body = :zlib.gzip("{" <> String.duplicate(" ", 5 * 1024 * 1024))

      serve(ctx, %{
        status: 200,
        body: body,
        etag: "bomb",
        headers: [{"content-encoding", "gzip"}, {"content-type", "application/feed+json"}],
        conditional?: true
      })

      {pid, first} = start_feed(ctx)
      monitor = Process.monitor(pid)
      send(pid, first)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
      assert %{"read_limit" => %{count: 1}} = gaps(ctx)
      assert %{status: "unavailable", stop_reason: "too_large"} = source_row(ctx)
      assert_received {:notice, ^ref, :too_large, %{}}
    end

    test "gzipped XML that unpacks past 32 MiB is past the read limit, not a gzip failure", ctx do
      ref = ctx.ref
      old = Calendar.strftime(DateTime.add(@now, -30, :day), "%a, %d %b %Y %H:%M:%S GMT")
      notes = String.duplicate("tide ", 20_000)

      # A few hundred long items past the horizon: Saxy reads past 32 MiB while
      # the keeper only counts them.
      item =
        "<item><guid>old</guid><pubDate>#{old}</pubDate><description>#{notes}</description></item>"

      count = div(33 * 1024 * 1024, byte_size(item))

      xml =
        ~s(<rss version="2.0"><channel><title>Old tides</title>) <>
          String.duplicate(item, count) <> "</channel></rss>"

      serve(ctx, %{
        status: 200,
        body: :zlib.gzip(xml),
        etag: "deep",
        headers: [{"content-encoding", "gzip"}],
        conditional?: true
      })

      {pid, first} = start_feed(ctx)
      monitor = Process.monitor(pid)
      send(pid, first)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
      assert %{status: "unavailable", stop_reason: "too_large"} = source_row(ctx)
      assert_received {:notice, ^ref, :too_large, %{}}
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

  # --- pinning -------------------------------------------------------------------

  describe "each hop is pinned to the address Net.Guard checked" do
    # Only the first lookup answers the public address. A request by name (the
    # old gap) dials the name; checking with one lookup and pinning from
    # another would pin loopback, which is refused. Either fails this test.
    test "the request goes to the checked address, where a second lookup would answer loopback",
         ctx do
      test = self()
      lookups = :counters.new(1, [])

      resolver = fn "feeds.example.test" ->
        :counters.add(lookups, 1, 1)

        if :counters.get(lookups, 1) == 1,
          do: {:ok, [@public_ip]},
          else: {:ok, [{127, 0, 0, 1}]}
      end

      answer = fn _name, _path -> feed_response(rss([{"a", "First", hours_ago(1)}])) end
      worker_opts = [resolver: resolver, req_options: [adapter: origin(test, answer)]]

      {pid, first} = start_feed(ctx, %{}, worker_opts)
      fire(pid, first)

      assert_received {:dialled, "93.184.216.34", "feeds.example.test", ~c"feeds.example.test",
                       "/releases.xml", nil}

      assert cue_ids(ctx) == ["a"]
    end

    # Finch raises, rather than returns, when its pool has no connection to give.
    test "a pool with no connection to give is a failed poll, retried after a minute", ctx do
      unavailable = fn _request ->
        raise RuntimeError,
              "Finch was unable to provide a connection within the timeout due to " <>
                "excess queuing for connections."
      end

      {pid, first} = start_feed(ctx, %{}, req_options: [adapter: unavailable])
      fire(pid, first)

      assert Process.alive?(pid)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, attempt: 1, error_class: "transport"}}

      next_poll(60_000)
    end

    test "a redirect is looked up, checked and pinned on its own, its TLS name its own host",
         ctx do
      test = self()

      resolver = fn host ->
        send(test, {:lookup, host})

        case host do
          "feeds.example.test" -> {:ok, [@public_ip]}
          "mirror.example.test" -> {:ok, [@other_public_ip]}
        end
      end

      answer = fn
        "feeds.example.test", _path ->
          redirect_response("https://mirror.example.test/larkspur/releases.xml")

        "mirror.example.test", _path ->
          feed_response(rss([{"a", "First", hours_ago(1)}]))
      end

      worker_opts = [resolver: resolver, req_options: [adapter: origin(test, answer)]]
      {pid, first} = start_feed(ctx, %{}, worker_opts)
      fire(pid, first)

      assert_received {:lookup, "feeds.example.test"}

      assert_received {:dialled, "93.184.216.34", "feeds.example.test", ~c"feeds.example.test",
                       "/releases.xml", nil}

      assert_received {:lookup, "mirror.example.test"}

      assert_received {:dialled, "93.184.216.35", "mirror.example.test", ~c"mirror.example.test",
                       "/larkspur/releases.xml", nil}

      assert cue_ids(ctx) == ["a"]
    end

    test "a redirect to a name that resolves to a private address is refused before it is dialled",
         ctx do
      test = self()

      resolver = fn
        "feeds.example.test" -> {:ok, [@public_ip]}
        "intranet.example.test" -> {:ok, [{10, 0, 0, 7}]}
      end

      answer = fn _name, _path -> redirect_response("https://intranet.example.test/feed") end
      worker_opts = [resolver: resolver, req_options: [adapter: origin(test, answer)]]

      {pid, first} = start_feed(ctx, %{}, worker_opts)
      fire(pid, first)

      assert_received {:dialled, "93.184.216.34", "feeds.example.test", _sni, _path, _proxy}
      refute_received {:dialled, _address, _name, _sni, _path, _proxy}
      assert cue_ids(ctx) == []

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, error_class: "blocked"}}
    end

    test "a relative redirect and relative item links resolve against the name, and an item " <>
           "keeps its id when the name moves to another address",
         ctx do
      test = self()
      watcher = insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})
      address = start_supervised!({Agent, fn -> @public_ip end}, id: :address)
      resolver = fn "feeds.example.test" -> {:ok, [Agent.get(address, & &1)]} end

      # No guid: the item's id is the digest of its link, title and time as written.
      body =
        ~s(<?xml version="1.0"?><rss version="2.0"><channel><title>Larkspur</title>) <>
          "<item><title>Patch notes</title><link>/posts/7</link>" <>
          "<pubDate>Sat, 10 Oct 2026 11:00:00 GMT</pubDate></item></channel></rss>"

      answer = fn
        _name, "/releases.xml" -> redirect_response("/v2/releases.xml")
        _name, "/v2/releases.xml" -> feed_response(body)
      end

      worker_opts = [resolver: resolver, req_options: [adapter: origin(test, answer)]]
      {pid, first} = start_feed(ctx, %{}, worker_opts)
      fire(pid, first)

      assert_received {:dialled, "93.184.216.34", "feeds.example.test", ~c"feeds.example.test",
                       "/releases.xml", nil}

      assert_received {:dialled, "93.184.216.34", "feeds.example.test", ~c"feeds.example.test",
                       "/v2/releases.xml", nil}

      assert [_item] = delivered(ctx, watcher)
      assert links(ctx) == ["https://feeds.example.test/posts/7"]

      Agent.update(address, fn _old -> @other_public_ip end)
      fire(pid, poll_every_interval())

      assert_received {:dialled, "93.184.216.35", "feeds.example.test", _sni, "/v2/releases.xml",
                       nil}

      assert length(cue_ids(ctx)) == 1
      assert links(ctx) == ["https://feeds.example.test/posts/7"]
    end

    test "behind a proxy, the feed tunnels to the checked address with the name in TLS", ctx do
      answer = fn _name, _path -> feed_response(rss([{"a", "First", hours_ago(1)}])) end

      worker_opts = [
        egress: Egress.new(proxy: "http://proxy.test:3128"),
        req_options: [adapter: origin(self(), answer)]
      ]

      {pid, first} = start_feed(ctx, %{}, worker_opts)
      fire(pid, first)

      assert_received {:dialled, "93.184.216.34", "feeds.example.test", ~c"feeds.example.test",
                       "/releases.xml", {:http, "proxy.test", 3128, _phases}}
    end

    test "behind a proxy, a proxy_bypass entry naming the feed's host still sends it direct",
         ctx do
      answer = fn _name, _path -> feed_response(rss([{"a", "First", hours_ago(1)}])) end

      worker_opts = [
        egress: Egress.new(proxy: "http://proxy.test:3128", proxy_bypass: [".example.test"]),
        req_options: [adapter: origin(self(), answer)]
      ]

      {pid, first} = start_feed(ctx, %{}, worker_opts)
      fire(pid, first)

      assert_received {:dialled, "93.184.216.34", "feeds.example.test", ~c"feeds.example.test",
                       "/releases.xml", nil}

      assert cue_ids(ctx) == ["a"]
    end
  end

  defp links(ctx) do
    ctx.conn
    |> rows("SELECT payload FROM cues WHERE source_ref = ? ORDER BY item_id", [ctx.ref])
    |> Enum.map(fn [payload] -> Jason.decode!(payload)["link"] end)
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

  describe "routing by words (M60_CUE_INTAKE_AT_SCALE.md §3.1)" do
    test "an llm watcher is offered only the items its words match; the rest are receipts",
         ctx do
      watcher =
        insert_watcher(ctx.conn, %{filter: "llm", sources: [ctx.ref], listen_for: ["larkspur"]})

      items = [
        {"released", "Larkspur 4.2 released", hours_ago(1)},
        {"closed", "The office is closed on Friday", hours_ago(2)}
      ]

      serve(ctx, feed(items, "v1"))
      {pid, first} = start_feed(ctx)
      fire(pid, first)

      assert cue_ids(ctx) == ["closed", "released"]
      assert delivered(ctx, watcher) == ["released"]

      assert [[nil, 0]] =
               rows(ctx.conn, "SELECT payload, routed_count FROM cues WHERE item_id = 'closed'")
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

    # Only X accounts reads a 401 as a sign-in to wait for; any other feed's 401
    # is an ordinary failure that counts toward the eighth-failure stop.
    test "a plain feed's 401 is an ordinary failure, counted toward the stop", ctx do
      ref = ctx.ref
      serve(ctx, %{status: 401, body: "no", etag: nil, headers: [], conditional?: false})

      {pid, first} = start_feed(ctx)
      monitor = Process.monitor(pid)
      fire(pid, first)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, attempt: 1, error_class: "http_status"}}

      for delay <- [60_000, 120_000, 240_000, 480_000, 960_000, 1_920_000] do
        fire(pid, next_poll(delay))
      end

      send(pid, next_poll(3_600_000))
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
      assert_received {:notice, ^ref, :unreachable, %{failures: 8}}
      refute_received {:notice, ^ref, :auth_failed, _data}
      assert source_row(ctx).status == "stopped"
    end

    test "a store that does not answer is a failed poll, backed off, and the worker runs on",
         ctx do
      stalling = start_supervised!({AcceptStallingRepo, forward_to: ctx.repo})
      {pid, first} = start_feed(ctx, %{}, repo: stalling, repo_timeout_ms: 50)

      ExUnit.CaptureLog.capture_log(fn -> fire(pid, first) end)

      next_poll(60_000)
      assert Process.alive?(pid)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, reason: :repo, attempt: 1}}
    end

    # A crash report prints the worker's state; a feed's URL can carry a token.
    test "its printed state names the source, never its URL or secrets", ctx do
      url = "https://feeds.example.test/releases.xml?token=feed-url-secret"
      {pid, _first} = start_feed(ctx, %{url: url, secrets: %{"token" => "stored-secret"}})

      printed = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)

      assert printed =~ ctx.ref
      refute printed =~ "feed-url-secret"
      refute printed =~ "stored-secret"
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

  # --- X accounts ------------------------------------------------------------------

  # M60_X_ACCOUNTS_SOURCE.md §3: a feed preset that asks X's recent search for
  # the handles' new posts with the X plugin's sign-in. X is the plug: it
  # reports each request (host, path, query, authorization) and answers what
  # the test serves.
  describe "an X accounts source" do
    setup ctx do
      Agent.update(ctx.server, fn _old -> {200, x_page([], nil)} end)
      tokens = start_supervised!({Agent, fn -> {:ok, "x-access-1"} end}, id: :tokens)
      refreshed = start_supervised!({Agent, fn -> {:ok, "x-access-2"} end}, id: :refreshed)
      %{tokens: tokens, refreshed: refreshed}
    end

    test "the first poll asks for the posts since watching began, reposts left out, signed in",
         ctx do
      {pid, first} = start_x(ctx)
      fire(pid, first)

      assert_received {:x_request, "api.x.com", "/2/tweets/search/recent", query,
                       ["Bearer x-access-1"]}

      assert query["query"] == "(from:nasa OR from:esa) -is:retweet"
      assert query["expansions"] == "author_id"
      assert query["max_results"] == "100"
      assert query["start_time"] == "2026-10-10T11:59:00Z"
      refute Map.has_key?(query, "since_id")

      row = source_row(ctx)
      assert row.status == "polling"
      assert Jason.decode!(row.cursor) == %{"start_time" => "2026-10-10T12:00:00Z"}
    end

    test "posts become items with their author and link, and the newest is the next since_id",
         ctx do
      insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})
      first = x_id(hours_ago(1))
      second = x_id(hours_ago(2))

      serve(
        ctx,
        {200,
         x_page(
           [x_post(first, "11", hours_ago(1)), x_post(second, "22", hours_ago(2))],
           %{"newest_id" => first, "oldest_id" => second, "result_count" => 2}
         )}
      )

      {pid, poll} = start_x(ctx)
      fire(pid, poll)

      assert cue_ids(ctx) == Enum.sort([first, second])
      [nasa, other] = payloads(ctx, [first, second])
      assert nasa["author"] == %{"id" => "11", "username" => "NASA", "name" => "NASA"}
      assert nasa["url"] == "https://x.com/NASA/status/#{first}"
      assert other["url"] == "https://x.com/i/status/#{second}"

      assert Jason.decode!(source_row(ctx).cursor) ==
               %{"since_id" => first, "start_time" => "2026-10-10T12:00:00Z"}

      serve(ctx, {200, x_page([], %{"result_count" => 0})})
      fire(pid, poll_every_interval())

      assert_received {:x_request, _host, _path, _first_query, _auth}
      assert_received {:x_request, _host, _path, query, _auth}
      assert query["since_id"] == first
      refute Map.has_key?(query, "start_time")

      # The empty answer kept the cursor.
      assert Jason.decode!(source_row(ctx).cursor) ==
               %{"since_id" => first, "start_time" => "2026-10-10T12:00:00Z"}
    end

    test "a next page is recorded as a page_limit gap, and the poll moves on", ctx do
      newest = x_id(hours_ago(1))

      serve(
        ctx,
        {200,
         x_page([x_post(newest, "11", hours_ago(1))], %{
           "newest_id" => newest,
           "result_count" => 1,
           "next_token" => "b26v89c19zqg8o3f"
         })}
      )

      {pid, poll} = start_x(ctx)
      fire(pid, poll)

      assert cue_ids(ctx) == [newest]
      assert %{"page_limit" => %{count: 1}} = gaps(ctx)
      assert Jason.decode!(source_row(ctx).cursor)["since_id"] == newest
    end

    test "with no X sign-in it waits as auth_failed, told once, checked on the backoff and " <>
           "never stopped by the count; a sign-in starts it with no save",
         ctx do
      ref = ctx.ref
      Agent.update(ctx.tokens, fn _old -> {:error, :x_plugin_not_installed} end)
      {pid, poll} = start_x(ctx)
      fire(pid, poll)

      refute_received {:x_request, _host, _path, _query, _auth}
      assert %{status: "auth_failed", stop_reason: "x_sign_in"} = source_row(ctx)
      assert_received {:notice, ^ref, :auth_failed, %{reason: "x_sign_in"}}

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :auth_failure, status: "auth_failed"}}

      # Ten more checks, past the eighth-failure stop, on the feed's backoff.
      delays =
        [60_000, 120_000, 240_000, 480_000, 960_000, 1_920_000] ++ List.duplicate(3_600_000, 4)

      for delay <- delays, do: fire(pid, next_poll(delay))

      assert Process.alive?(pid)
      refute_received {:notice, ^ref, _kind, _data}
      assert source_row(ctx).status == "auth_failed"

      Agent.update(ctx.tokens, fn _old -> {:ok, "x-access-2"} end)
      fire(pid, next_poll(3_600_000))

      assert_received {:x_request, _host, _path, _query, ["Bearer x-access-2"]}
      assert %{status: "polling", stop_reason: nil} = source_row(ctx)
      poll_every_interval()
    end

    # A token server that does not answer exits the call; that is a sign-in
    # wait like any other, never a crash (five crashes would stop the source).
    test "a token server that does not answer leaves it waiting for the X sign-in", ctx do
      ref = ctx.ref

      wedged = fn _profile ->
        exit({:timeout, {GenServer, :call, [:x_tokens, :get_token, 15_000]}})
      end

      sign_in = fn ->
        XAccounts.sign_in_token(
          find: fn "x" -> {:ok, x_plugin()} end,
          enabled: fn -> ["x"] end,
          get_token: wedged
        )
      end

      {pid, poll} = start_x(ctx, token_getter: sign_in)
      log = ExUnit.CaptureLog.capture_log(fn -> fire(pid, poll) end)

      assert Process.alive?(pid)
      assert log =~ "token_server_unavailable"
      assert %{status: "auth_failed", stop_reason: "x_sign_in"} = source_row(ctx)
      assert_received {:notice, ^ref, :auth_failed, %{reason: "x_sign_in"}}
      next_poll(60_000)
    end

    test "X refusing the token is refreshed once and asked again with the new one", ctx do
      insert_watcher(ctx.conn, %{filter: "none", sources: [ctx.ref]})
      newest = x_id(hours_ago(1))
      page = x_page([x_post(newest, "11", hours_ago(1))], %{"newest_id" => newest})

      serve(ctx, %{
        "Bearer x-access-1" => {401, ~s({"title":"Unauthorized","status":401})},
        "Bearer x-access-2" => {200, page}
      })

      {pid, poll} = start_x(ctx)
      fire(pid, poll)

      assert_received {:x_request, _host, _path, _query, ["Bearer x-access-1"]}
      assert_received :refreshed
      assert_received {:x_request, _host, _path, _query, ["Bearer x-access-2"]}
      refute_received :refreshed
      assert cue_ids(ctx) == [newest]
      assert %{status: "polling", stop_reason: nil} = source_row(ctx)
      poll_every_interval()
    end

    test "a second 401 after the refresh, or a refresh that fails, is the sign-in wait", ctx do
      ref = ctx.ref
      serve(ctx, {401, ~s({"title":"Unauthorized","status":401})})
      {pid, poll} = start_x(ctx)
      fire(pid, poll)

      assert_received {:x_request, _host, _path, _query, ["Bearer x-access-1"]}
      assert_received {:x_request, _host, _path, _query, ["Bearer x-access-2"]}
      refute_received {:x_request, _host, _path, _query, _auth}
      assert_received :refreshed
      refute_received :refreshed
      assert %{status: "auth_failed", stop_reason: "x_sign_in"} = source_row(ctx)
      assert_received {:notice, ^ref, :auth_failed, %{reason: "x_sign_in"}}

      Agent.update(ctx.refreshed, fn _old -> {:error, :refresh_token_revoked} end)
      fire(pid, next_poll(60_000))

      assert_received {:x_request, _host, _path, _query, ["Bearer x-access-1"]}
      refute_received {:x_request, _host, _path, _query, _auth}
      assert source_row(ctx).status == "auth_failed"
      next_poll(120_000)
    end

    test "leaving the sign-in wait through another failure stops the row claiming a sign-in",
         ctx do
      Agent.update(ctx.tokens, fn _old -> {:error, :not_found} end)
      {pid, poll} = start_x(ctx)
      fire(pid, poll)
      assert %{status: "auth_failed", stop_reason: "x_sign_in"} = source_row(ctx)

      Agent.update(ctx.tokens, fn _old -> {:ok, "x-access-1"} end)
      serve(ctx, {403, ~s({"title":"Forbidden","detail":"Invented 3301."})})
      ExUnit.CaptureLog.capture_log(fn -> fire(pid, next_poll(60_000)) end)

      assert %{status: "polling", stop_reason: nil} = source_row(ctx)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, attempt: 1, error_class: "http_status"}}

      next_poll(60_000)
    end

    test "watching starts at the first read with the X sign-in, not when the sign-in was missing",
         ctx do
      Agent.update(ctx.tokens, fn _old -> {:error, :not_found} end)
      {pid, poll} = start_x(ctx)
      fire(pid, poll)

      # Nothing is written to the cursor while X is not connected.
      assert source_row(ctx).cursor == nil

      # X is connected eight days later: no week of backlog is asked for.
      set_clock(ctx, ~U[2026-10-18 12:00:00Z])
      Agent.update(ctx.tokens, fn _old -> {:ok, "x-access-1"} end)
      fire(pid, next_poll(60_000))

      assert_received {:x_request, _host, _path, query, ["Bearer x-access-1"]}
      assert query["start_time"] == "2026-10-18T11:59:00Z"
      assert Jason.decode!(source_row(ctx).cursor) == %{"start_time" => "2026-10-18T12:00:00Z"}
    end

    test "after a restart it asks for the posts after the newest one its row kept", ctx do
      newest = x_id(hours_ago(3))
      cursor = Jason.encode!(%{"since_id" => newest, "start_time" => "2026-10-09T08:00:00Z"})

      {:ok, _row} =
        Repo.cues_call(
          CuesSql,
          {:source_touch, ctx.ref, %{status: "polling", cursor: cursor}, hours_ago(2)},
          server: ctx.repo
        )

      {pid, poll} = start_x(ctx)
      fire(pid, poll)

      assert_received {:x_request, _host, _path, query, _auth}
      assert query["since_id"] == newest
      refute Map.has_key?(query, "start_time")
    end

    test "the access token never reaches the log or a trace", ctx do
      secret_1 = "x-access-invented-secret-5153"
      secret_2 = "x-access-invented-secret-6264"
      Agent.update(ctx.tokens, fn _old -> {:ok, secret_1} end)
      Agent.update(ctx.refreshed, fn _old -> {:ok, secret_2} end)
      serve(ctx, {401, ~s({"title":"Unauthorized","status":401})})
      {pid, poll} = start_x(ctx)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          fire(pid, poll)
          serve(ctx, {403, ~s({"title":"Forbidden","detail":"Invented 4410."})})
          fire(pid, next_poll(60_000))
        end)

      assert_received {:x_request, _host, _path, _query, ["Bearer " <> ^secret_1]}
      assert_received {:x_request, _host, _path, _query, ["Bearer " <> ^secret_2]}
      assert log =~ "Invented 4410."

      traces = drain_traces([])
      assert traces != []

      for secret <- [secret_1, secret_2] do
        refute log =~ secret
        refute inspect(traces, limit: :infinity, printable_limit: :infinity) =~ secret
      end
    end

    test "X refusing the sign-in (401) is the same wait", ctx do
      ref = ctx.ref
      serve(ctx, {401, ~s({"title":"Unauthorized","detail":"Unauthorized","status":401})})
      {pid, poll} = start_x(ctx)
      fire(pid, poll)

      assert %{status: "auth_failed", stop_reason: "x_sign_in"} = source_row(ctx)
      assert_received {:notice, ^ref, :auth_failed, %{reason: "x_sign_in"}}
      next_poll(60_000)
    end

    test "a 403 is an ordinary failure: X's words go to the log, never to a notice or the row",
         ctx do
      ref = ctx.ref
      detail = "Your enrolled account does not have access to this endpoint (invented 5521)."

      serve(ctx, {403, Jason.encode!(%{"title" => "Forbidden", "detail" => detail})})
      {pid, poll} = start_x(ctx)

      log = ExUnit.CaptureLog.capture_log(fn -> fire(pid, poll) end)

      assert log =~ detail
      next_poll(60_000)
      refute_received {:notice, ^ref, _kind, _data}
      refute match?(%{status: "auth_failed"}, source_row(ctx))

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, attempt: 1, error_class: "http_status"}}
    end

    test "a redirect is not followed with the X sign-in", ctx do
      serve(ctx, {302, "", [{"location", "https://elsewhere.example.test/collect"}]})
      {pid, poll} = start_x(ctx)
      fire(pid, poll)

      assert_received {:x_request, "api.x.com", _path, _query, _auth}
      refute_received {:x_request, "elsewhere.example.test", _path, _query, _auth}
      next_poll(60_000)
    end
  end

  defp start_x(ctx, worker_opts \\ []) do
    test = self()

    refresher = fn ->
      send(test, :refreshed)
      Agent.get(ctx.refreshed, & &1)
    end

    opts = [
      req_options: [plug: x_plug(ctx.server, test)],
      token_getter: fn -> Agent.get(ctx.tokens, & &1) end,
      token_refresher: refresher
    ]

    start_feed(
      ctx,
      %{preset: "x_accounts", url: nil, handles: ["nasa", "esa"]},
      Keyword.merge(opts, worker_opts)
    )
  end

  defp x_plugin do
    %Plugin{
      schema_version: 1,
      name: "x",
      display_name: "X",
      description: "Post, search, and read on X.",
      category: "productivity",
      version: "1.0.1",
      default_enabled?: false,
      auth: %{type: :oauth2, provider: "x", scopes: []},
      tools: [],
      skills: [],
      path: "/plugins/x"
    }
  end

  defp drain_traces(acc) do
    receive do
      {:telemetry, _event, _measurements, _metadata} = trace -> drain_traces([trace | acc])
    after
      0 -> acc
    end
  end

  defp x_plug(server, test) do
    fn conn ->
      query = URI.decode_query(conn.query_string)
      auth = Plug.Conn.get_req_header(conn, "authorization")
      send(test, {:x_request, host_seen(conn), conn.request_path, query, auth})
      x_reply(conn, answer(Agent.get(server, & &1), auth))
    end
  end

  # One answer for every request, or one per Authorization header.
  defp answer(%{} = by_auth, [auth]), do: Map.fetch!(by_auth, auth)
  defp answer(reply, _auth), do: reply

  defp x_reply(conn, {status, body}), do: x_reply(conn, {status, body, []})

  defp x_reply(conn, {status, body, headers}) do
    [{"content-type", "application/json"} | headers]
    |> Enum.reduce(conn, fn {name, value}, acc -> Plug.Conn.put_resp_header(acc, name, value) end)
    |> Plug.Conn.send_resp(status, body)
  end

  # An X post id made at `at`, its time in the high bits as X makes them.
  defp x_id(at) do
    ms = DateTime.to_unix(at, :millisecond) - 1_288_834_974_657
    Integer.to_string(Bitwise.bsl(ms, 22) + 1_031)
  end

  defp x_post(id, author_id, at) do
    %{
      "id" => id,
      "text" => "Invented post #{id}",
      "author_id" => author_id,
      "created_at" => DateTime.to_iso8601(at)
    }
  end

  # X's answer: no `data` or `includes` when nothing matched, as X sends it.
  defp x_page([], meta), do: Jason.encode!(%{"meta" => meta || %{"result_count" => 0}})

  defp x_page(posts, meta) do
    users = [%{"id" => "11", "username" => "NASA", "name" => "NASA"}]
    Jason.encode!(%{"data" => posts, "includes" => %{"users" => users}, "meta" => meta})
  end

  defp payloads(ctx, ids) do
    for id <- ids do
      [[payload]] =
        rows(ctx.conn, "SELECT payload FROM cues WHERE source_ref = ? AND item_id = ?", [
          ctx.ref,
          id
        ])

      Jason.decode!(payload)
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
