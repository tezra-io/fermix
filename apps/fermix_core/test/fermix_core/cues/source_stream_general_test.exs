defmodule FermixCore.Cues.Source.StreamGeneralTest do
  # The general WebSocket source: a stream with no preset. One worker per test
  # on its own temp Repo, built from a config section as the daemon resolves
  # it, with FakeCueTransport driven by hand, a hand-driven clock and captured
  # timers: no network, no real time. Its secrets live in the stub writer under
  # this test's own ref. async: false because some cases assert that a secret
  # is in no log line, and another flips the content gate.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Source.Stream
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.FakeCueTransport
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-12 14:00:00Z]
  @wait_ms 10_000
  # Invented credentials; the secret carries a quote and a backslash, which the
  # sign-in message must escape.
  @key "PKQ7TZ2M4VXR9WEN3HBA"
  @secret ~S(zW8d"Lq3\Nf6Rt0Yp2Ks5Hv9Jm1Xc4Bg7)
  @subscribe ~s({"action":"subscribe","news":["*"]})

  setup do
    ctx = start_repo("stream_general")
    ref = "news-#{System.unique_integer([:positive])}"
    clock = start_supervised!({Agent, fn -> @now end}, id: :clock)

    :ok = SecretWriter.put({:cue_source, ref, :key}, @key, store: :keyring)
    :ok = SecretWriter.put({:cue_source, ref, :secret}, @secret, store: :keyring)

    on_exit(fn ->
      for field <- [:key, :secret],
          do: SecretWriter.delete({:cue_source, ref, field}, store: :keyring)
    end)

    TelemetryCapture.attach([[:fermix, :cue, :source], [:fermix, :cue, :lifecycle]],
      source_ref: ref
    )

    Map.merge(ctx, %{ref: ref, clock: clock})
  end

  # --- helpers ---------------------------------------------------------------

  # Shaped like a broker's real-time news stream: the key and secret as
  # headers and in a sign-in message, frames that are lists of messages typed
  # by "T", stories of type "n", errors of type "error".
  defp section(overrides) do
    Map.merge(
      %{
        "kind" => "stream",
        "url" => "wss://stream.example.com/v2/news",
        "key" => "@keyring",
        "secret" => "@keyring",
        "key_header" => "X-Feed-Key",
        "secret_header" => "X-Feed-Secret",
        "auth_message" => ~s({"action":"auth","key":"{{key}}","secret":"{{secret}}"}),
        "subscribe_message" => @subscribe,
        "type_path" => "T",
        "item_types" => ["n"],
        "error_types" => ["error"],
        "id_path" => "id",
        "revision_path" => "updated_at",
        "time_path" => "created_at",
        "subject_path" => "symbols.0"
      },
      overrides
    )
  end

  defp start_stream(ctx, overrides \\ %{}) do
    test = self()
    cues = Config.normalize(%{"sources" => %{ctx.ref => section(overrides)}})
    {:ok, source} = Config.source(ctx.ref, cues)

    opts = [
      source: source,
      repo: ctx.repo,
      clock: fn -> Agent.get(ctx.clock, & &1) end,
      monotonic_ms: fn -> 0 end,
      schedule: fn message, ms -> send(test, {:scheduled, message, ms}) end,
      transport: FakeCueTransport,
      transport_opts: [test: test],
      admit: fn _ref, n, _now_ms -> n end,
      notify: fn ref, kind, data, _opts -> send(test, {:notice, ref, kind, data}) && :sent end
    ]

    pid = start_supervised!({Stream, opts})
    {pid, scheduled(:connect, 0)}
  end

  defp scheduled(kind, expected_ms) do
    assert_receive {:scheduled, {:timer, ^kind, _token} = message, ^expected_ms}
    message
  end

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
    {_url, socket, _opts} = dial(pid, message)
    deliver(pid, {:cue_stream, socket, :connected})
    socket
  end

  defp frame(pid, socket, messages),
    do: deliver(pid, {:cue_stream, socket, {:frame, {:text, Jason.encode!(messages)}}})

  defp story(id, opts \\ []) do
    %{
      "T" => "n",
      "id" => id,
      "headline" => Keyword.get(opts, :headline, "Harrowgate Freight lifts its outlook"),
      "symbols" => ["HGFT"],
      "created_at" => "2026-10-12T13:59:00Z",
      "updated_at" => Keyword.get(opts, :updated_at, "2026-10-12T13:59:00Z")
    }
  end

  defp refusal, do: %{"T" => "error", "code" => 406, "msg" => "connection limit exceeded"}

  # One connection that ends on the service's error: dialled, opened, the
  # frame (one error by default), and the close it causes.
  defp refused_once(pid, message, messages \\ [refusal()]) do
    socket = connect(pid, message)
    frame(pid, socket, messages)
    assert_receive {:closed, ^socket}
    socket
  end

  # `n` refused connections, the backoff growing from `failures` before them;
  # answers the next dial.
  defp refusals(pid, dial, n, failures \\ 0, messages \\ [refusal()]) do
    Enum.reduce(1..n, dial, fn i, dial ->
      refused_once(pid, dial, messages)
      next_dial(failures + i)
    end)
  end

  # The redial after the `failures`-th failure in a row: 1 s doubling to 60 s.
  defp next_dial(failures),
    do: scheduled(:connect, min(1_000 * Integer.pow(2, failures - 1), 60_000))

  # Forgets the timers earlier connections armed, so the next one is fresh.
  defp drain(kind) do
    receive do
      {:scheduled, {:timer, ^kind, _token}, _ms} -> drain(kind)
    after
      0 -> :ok
    end
  end

  defp advance(ctx, seconds), do: Agent.update(ctx.clock, &DateTime.add(&1, seconds, :second))

  defp flush(pid), do: deliver(pid, scheduled(:flush, 250))

  defp cues(ctx) do
    rows(
      ctx.conn,
      "SELECT item_id, revision, subject FROM cues WHERE source_ref = ? ORDER BY id",
      [
        ctx.ref
      ]
    )
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

  # A value as it sits inside a JSON string.
  defp escaped(value) do
    json = Jason.encode!(value)
    binary_part(json, 1, byte_size(json) - 2)
  end

  # --- signing in ------------------------------------------------------------

  describe "signing in" do
    test "the upgrade carries the sign-in headers and the 1 MiB cap, and the sign-in and " <>
           "subscribe messages go out in that order as soon as the connection opens",
         ctx do
      {pid, first} = start_stream(ctx)
      {url, socket, opts} = dial(pid, first)

      assert url == "wss://stream.example.com/v2/news"
      assert opts[:headers] == [{"X-Feed-Key", @key}, {"X-Feed-Secret", @secret}]
      assert opts[:max_frame_bytes] == 1024 * 1024
      assert [sign_in, @subscribe] = opts[:messages]

      assert sign_in ==
               ~s({"action":"auth","key":"#{@key}","secret":"#{escaped(@secret)}"})

      assert Jason.decode!(sign_in) == %{"action" => "auth", "key" => @key, "secret" => @secret}

      # Built once, when dialling: the upgrade sends nothing more.
      deliver(pid, {:cue_stream, socket, :connected})
      refute_received {:sent, ^socket, _text}
    end

    test "the worker keeps no secret in its state once connected", ctx do
      {pid, first} = start_stream(ctx)
      _socket = connect(pid, first)

      state = pid |> :sys.get_state() |> inspect(limit: :infinity, printable_limit: :infinity)
      refute state =~ @key
      refute state =~ escaped(@secret)
      refute state =~ "Lq3"
    end

    test "a 401 or 403 at the upgrade stops it as auth_failed", ctx do
      for status <- [401, 403] do
        ref = ctx.ref
        {pid, first} = start_stream(ctx)
        monitor = Process.monitor(pid)
        {_url, socket, _opts} = dial(pid, first)

        send(socket, {:die, {:upgrade_refused, status}})

        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
        assert_received {:notice, ^ref, :auth_failed, _data}
        assert source_row(ctx).status == "auth_failed"
      end
    end
  end

  # --- reading -----------------------------------------------------------------

  describe "reading" do
    test "each story becomes a cue, an update a new revision, control messages are " <>
           "skipped, and every frame is acknowledged once handled",
         ctx do
      {pid, first} = start_stream(ctx)
      socket = connect(pid, first)

      frame(pid, socket, [%{"T" => "success", "msg" => "authenticated"}])
      frame(pid, socket, [%{"T" => "subscription", "news" => ["*"]}])
      frame(pid, socket, [story(24_918_784), story(24_918_785)])
      frame(pid, socket, [story(24_918_784, updated_at: "2026-10-12T13:59:40Z")])
      flush(pid)

      for _frame <- 1..4, do: assert_receive({:acked, ^socket})

      assert cues(ctx) == [
               ["24918784", "2026-10-12T13:59:00Z", "HGFT"],
               ["24918785", "2026-10-12T13:59:00Z", "HGFT"],
               ["24918784", "2026-10-12T13:59:40Z", "HGFT"]
             ]

      assert source_row(ctx).status == "connected"
    end

    test "a message with no id and a frame that is not JSON are rejects", ctx do
      {pid, first} = start_stream(ctx)
      socket = connect(pid, first)

      frame(pid, socket, [Map.delete(story(1), "id")])
      deliver(pid, {:cue_stream, socket, {:frame, {:text, "not json"}}})
      flush(pid)

      assert cues(ctx) == []
      assert source_row(ctx).reject_counts == %{"invalid" => 2}
    end

    test "a frame of more than 100 messages keeps 100 and records the rest as a page_limit gap",
         ctx do
      {pid, first} = start_stream(ctx)
      socket = connect(pid, first)

      frame(pid, socket, Enum.map(1..103, &story/1))
      flush(pid)

      assert length(cues(ctx)) == 100
      assert %{"page_limit" => %{count: 3}} = gaps(ctx)
    end

    test "a frame over 1 MiB closes the connection with a read_limit gap, and so does a " <>
           "connection the transport ends at one",
         ctx do
      {pid, first} = start_stream(ctx)
      socket = connect(pid, first)

      big = String.duplicate("x", 1024 * 1024 + 1)
      deliver(pid, {:cue_stream, socket, {:frame, {:text, big}}})
      assert_receive {:closed, ^socket}
      assert %{"read_limit" => %{count: 1}} = gaps(ctx)

      socket = connect(pid, next_dial(1))
      send(socket, {:die, :frame_too_large})
      next_dial(2)
      assert %{"read_limit" => %{count: 2}} = gaps(ctx)
    end
  end

  # --- failures ----------------------------------------------------------------

  describe "failures" do
    test "the eighth connection in a row that ends on the service's error stops it, with " <>
           "one notice",
         ctx do
      ref = ctx.ref
      {pid, first} = start_stream(ctx)
      monitor = Process.monitor(pid)

      dial = refusals(pid, first, 7)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, reason: :service_error}}

      assert source_row(ctx).status == "reconnecting"
      refused_once(pid, dial)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
      assert_received {:notice, ^ref, :refused, %{}}
      refute_received {:notice, ^ref, :refused, _data}
      assert source_row(ctx).status == "stopped"

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :stopped, status: "stopped", reason: :refused}}
    end

    test "an item resets the count: a connection that delivered one does not count", ctx do
      {pid, first} = start_stream(ctx)
      monitor = Process.monitor(pid)

      dial = refusals(pid, first, 7)

      socket = connect(pid, dial)
      frame(pid, socket, [story(77_001), refusal()])
      assert_receive {:closed, ^socket}

      dial = refusals(pid, next_dial(1), 7, 1)
      refute_received {:DOWN, ^monitor, :process, ^pid, _reason}
      assert Process.alive?(pid)
      assert [["77001", _revision, _subject]] = cues(ctx)

      refused_once(pid, dial)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
    end

    test "an item after the service's error does not make the closing connection healthy",
         ctx do
      {pid, first} = start_stream(ctx)
      monitor = Process.monitor(pid)

      dial = refusals(pid, first, 7)
      refused_once(pid, dial, [refusal(), story(77_002)])

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @wait_ms
      assert source_row(ctx).status == "stopped"
    end

    test "a second error on a connection already closing counts once", ctx do
      {pid, first} = start_stream(ctx)
      monitor = Process.monitor(pid)

      log =
        capture_log(fn ->
          dial = refusals(pid, first, 7, 0, [refusal(), refusal()])
          refute_received {:DOWN, ^monitor, :process, ^pid, _reason}
          refused_once(pid, dial, [refusal(), refusal()])
          wait_down(monitor, pid)
        end)

      assert log =~ "the service sent another error"
      assert source_row(ctx).status == "stopped"
    end

    test "a secret that cannot be read is a disconnect before dialling", ctx do
      :ok = SecretWriter.delete({:cue_source, ctx.ref, :key}, store: :keyring)

      log =
        capture_log(fn ->
          {pid, first} = start_stream(ctx)
          deliver(pid, first)
          next_dial(1)
        end)

      refute_received {:dialed, _url, _socket, _opts}
      assert log =~ "{:secret, :key, :missing_secret}"

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, reason: :secret_unavailable}}
    end

    # A batch that fails to commit closes the connection; its batch timer goes
    # with it, so nothing writes the row as connected after the drop, and what
    # was still waiting is taken by the next connection's first flush.
    test "a failed batch: nothing writes connected after the drop, and the next connection " <>
           "takes what waited",
         ctx do
      {pid, first} = start_stream(ctx)
      socket = connect(pid, first)

      exec!(
        ctx.conn,
        "CREATE TRIGGER cue_insert_fails BEFORE INSERT ON cues " <>
          "BEGIN SELECT RAISE(ABORT, 'disk full'); END",
        []
      )

      {dial, _log} =
        with_log(fn ->
          frame(pid, socket, Enum.map(1..60, &story/1))
          assert_receive {:closed, ^socket}
          next_dial(1)
        end)

      exec!(ctx.conn, "DROP TRIGGER cue_insert_fails", [])
      assert source_row(ctx).status == "reconnecting"

      # The batch timers armed on the dropped connection: stale, and the worker
      # is not connected, so neither writes.
      for _armed <- 1..2, do: deliver(pid, scheduled(:flush, 250))
      assert source_row(ctx).status == "reconnecting"
      assert cues(ctx) == []

      drain(:heartbeat)
      socket = connect(pid, dial)
      advance(ctx, 30)
      deliver(pid, scheduled(:heartbeat, 30_000))
      assert_receive {:pinged, ^socket}
      assert length(cues(ctx)) == 10
      assert source_row(ctx).status == "connected"
    end

    test "a drop reconnects at the live tip: no rewind, no backfill and no gap", ctx do
      seed_last_good(ctx, DateTime.add(@now, -3_600, :second))
      {pid, first} = start_stream(ctx)
      socket = connect(pid, first)

      send(socket, {:die, {:remote_closed, 1006}})
      {url, _socket, _opts} = dial(pid, next_dial(1))

      assert url == "wss://stream.example.com/v2/news"
      assert gaps(ctx) == %{}
      refute_received {:telemetry, [:fermix, :cue, :source], _m, %{phase: :backfill}}
    end

    test "an outage is told after 15 minutes even with a last good time, in words that " <>
           "say nothing was recorded",
         ctx do
      ref = ctx.ref
      seed_last_good(ctx, DateTime.add(@now, -3_600, :second))
      {pid, first} = start_stream(ctx)
      socket = connect(pid, first)

      send(socket, {:die, {:connect_failed, :nxdomain}})
      down_check = scheduled(:down, 900_000)
      deliver(pid, down_check)

      assert_received {:notice, ^ref, :down, %{catch_up: false}}
    end

    test "an address the guard refuses stops it as unavailable with an :unreachable notice",
         ctx do
      ref = ctx.ref
      {pid, first} = start_stream(ctx)
      monitor = Process.monitor(pid)
      {_url, socket, _opts} = dial(pid, first)

      log =
        capture_log(fn -> send(socket, {:die, :address_refused}) && wait_down(monitor, pid) end)

      assert log =~ "private, loopback or link-local"
      assert_received {:notice, ^ref, :unreachable, %{reason: "address_refused"}}
      assert source_row(ctx).status == "unavailable"

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :stopped, reason: :address_refused}}
    end
  end

  defp wait_down(monitor, pid), do: assert_receive({:DOWN, ^monitor, :process, ^pid, :normal})

  # --- a healthy connection --------------------------------------------------------

  # An upgrade proves nothing: a service may accept the connection and then
  # refuse it. Only its first item, or a heartbeat that finds it alive, ends
  # the outage and resets the backoff and the count.
  describe "a healthy connection" do
    test "a refusal loop backs off 1, 2, 4 s, shows reconnecting, and tells the outage " <>
           "once, 15 minutes after it began",
         ctx do
      ref = ctx.ref
      {pid, first} = start_stream(ctx)

      refused_once(pid, first)
      down_check = scheduled(:down, 900_000)
      dial = scheduled(:connect, 1_000)
      refused_once(pid, dial)
      dial = scheduled(:connect, 2_000)
      refused_once(pid, dial)
      dial = scheduled(:connect, 4_000)
      refute_received {:scheduled, {:timer, :down, _token}, _ms}
      assert source_row(ctx).status == "reconnecting"

      # The notice comes even while a refused connection is open.
      _socket = connect(pid, dial)
      deliver(pid, down_check)
      assert_received {:notice, ^ref, :down, %{catch_up: false}}
    end

    test "the first item ends the outage and resets the backoff", ctx do
      {pid, first} = start_stream(ctx)
      dial = refusals(pid, first, 2)
      drain(:down)

      socket = connect(pid, dial)
      assert source_row(ctx).status == "reconnecting"
      frame(pid, socket, [story(61_001)])
      assert source_row(ctx).status == "connected"

      send(socket, {:die, {:remote_closed, 1006}})
      next_dial(1)
      scheduled(:down, 900_000)
    end

    test "a quiet connection is healthy at the first heartbeat that finds it alive", ctx do
      {pid, first} = start_stream(ctx)
      dial = refusals(pid, first, 2)
      drain(:heartbeat)

      socket = connect(pid, dial)
      heartbeat = scheduled(:heartbeat, 30_000)
      assert source_row(ctx).status == "reconnecting"

      advance(ctx, 30)
      deliver(pid, heartbeat)
      assert_receive {:pinged, ^socket}
      assert source_row(ctx).status == "connected"

      send(socket, {:die, {:remote_closed, 1006}})
      next_dial(1)
    end

    test "a quiet healthy connection clears the refusal count", ctx do
      {pid, first} = start_stream(ctx)
      monitor = Process.monitor(pid)
      dial = refusals(pid, first, 7)
      drain(:heartbeat)

      socket = connect(pid, dial)
      advance(ctx, 30)
      deliver(pid, scheduled(:heartbeat, 30_000))
      frame(pid, socket, [refusal()])
      assert_receive {:closed, ^socket}

      refusals(pid, next_dial(1), 6, 1)
      refute_received {:DOWN, ^monitor, :process, ^pid, _reason}
      assert Process.alive?(pid)
    end
  end

  # --- what reaches the log, the trace and the rows ----------------------------

  describe "secrets and the service's words" do
    setup do
      telemetry = Application.get_env(:fermix_core, :telemetry)

      on_exit(fn ->
        if telemetry,
          do: Application.put_env(:fermix_core, :telemetry, telemetry),
          else: Application.delete_env(:fermix_core, :telemetry)
      end)

      Application.put_env(
        :fermix_core,
        :telemetry,
        Keyword.put(telemetry || [], :capture_content, true)
      )

      :ok
    end

    test "no secret reaches a log line or a trace event, through a connection, an error, " <>
           "a drop and a secret that can no longer be read",
         ctx do
      log =
        capture_log(fn ->
          {pid, first} = start_stream(ctx)
          socket = connect(pid, first)
          frame(pid, socket, [story(5_001), refusal()])
          assert_receive {:closed, ^socket}

          :ok = SecretWriter.delete({:cue_source, ctx.ref, :secret}, store: :keyring)
          deliver(pid, next_dial(1))
          next_dial(2)
        end)

      assert log =~ "connection limit exceeded"
      assert log =~ "{:secret, :secret, :missing_secret}"
      events = collect_events([])

      for text <- [log, inspect(events, limit: :infinity, printable_limit: :infinity)],
          value <- [@key, @secret, escaped(@secret), "Lq3"] do
        refute text =~ value
      end
    end

    # A crashed transport's exit carries a stacktrace whose arguments could hold
    # a sign-in header: the log names the error, never the term.
    test "a crashed transport is logged by its error's banner, never its arguments", ctx do
      {pid, first} = start_stream(ctx)
      {_url, socket, opts} = dial(pid, first)
      stacktrace = [{FermixTestSupport.FakeCueTransport, :upgrade, [opts[:headers]], []}]

      log =
        capture_log(fn ->
          send(socket, {:die, {%RuntimeError{message: "upgrade went wrong"}, stacktrace}})
          next_dial(1)
        end)

      assert log =~ "** (RuntimeError) upgrade went wrong"
      refute log =~ @key
      refute log =~ "Lq3"
    end

    test "the service's words, bounded, reach the log and the trace, never the notice or " <>
           "the row",
         ctx do
      ref = ctx.ref
      long = %{"T" => "error", "code" => 500, "msg" => String.duplicate("overloaded\n", 100)}

      log =
        capture_log(fn ->
          {pid, first} = start_stream(ctx)
          socket = connect(pid, first)
          frame(pid, socket, [long])
          assert_receive {:closed, ^socket}
          next_dial(1)
        end)

      assert_received {:telemetry, [:fermix, :cue, :source], _m,
                       %{phase: :disconnect, reason: :service_error, content: words}}

      assert byte_size(words) <= 512
      assert words =~ ~s("code":500)
      refute words =~ "\n"
      assert log =~ "overloaded"
      refute_received {:notice, ^ref, _kind, _data}
      assert source_row(ctx).status == "reconnecting"
    end
  end

  defp collect_events(acc) do
    receive do
      {:telemetry, _event, _measurements, _metadata} = event -> collect_events([event | acc])
    after
      0 -> acc
    end
  end
end
