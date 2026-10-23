defmodule FermixCore.Cues.Source.Stream do
  @moduledoc """
  One stream source's connection (M60 §6.3, §6.9, §6.10), built for the
  `bluesky_jetstream` preset: Bluesky's public Jetstream over a WebSocket,
  decoded by `Cues.Jetstream`. A stream source without that preset is
  `unavailable` and its worker stops.

  The worker owns a transport process (`Cues.Source.Stream.Socket` in
  production: WebSockex with `Net.Tls`, refusing a proxied route through
  `Net.Egress.ensure_direct/2`), monitors it, and keeps everything that must
  survive a reconnect itself: the last good time, the backoff, the batch.

  **Cursor and backfill.** `cue_sources.last_good_at` is the local time the
  connection was last known good, written in the same transaction as the cues
  it covers (a frame or a pong is the evidence; a heartbeat writes it when no
  item came). While a reconnect is still replaying, the evidence is the newest
  event time seen instead, so a drop mid-replay resumes where the replay got
  to; the replay is over at the first event from after the connection opened,
  or at a heartbeat with no frame since the last. A reconnect resumes from the
  last good time minus 5 minutes, in unix
  microseconds, reaching back at most 24 hours: anything older is a
  `disconnect` gap with its range, and so is an `OutdatedCursor` notice from the
  service (it clamped the resume point). A new source starts at the live tip.
  Backfilled items beyond 1,000 per connection are a `backfill_limit` gap.
  Repeats are duplicates by identity. `cue_sources.cursor` holds the newest
  event time seen, for reading only.

  **Batches.** Items are accepted every 250 ms, or at once when 50 are waiting,
  through `Cues.Ingest.accept/3` with the rate buckets (`Cues.Buckets.admit/3`)
  and `status: "connected"`.

  **Limits.** A frame over 128 KiB closes the connection with a `read_limit`
  gap, and the next connection resumes from the time of that close, so the
  same frame is not replayed; the gap's range runs from what was known
  complete to the close (WebSockex holds a whole frame in memory before this
  cap can see it). A connection silent past 90 seconds (no frame, no
  answer to the 30-second ping) is closed and dialled again.

  **Failures.** Reconnects back off from one second doubling to a minute, and
  never stop. The owner is told of an outage once (`:down`) when it is longer
  than 15 minutes and longer than a reconnect could still replay (24 hours back
  from the resume point; a source that never had a good time has nothing to
  replay). A refused credential (HTTP 401 or 403 at the handshake)
  stops the worker with status `auth_failed` and a notice (`:auth_failed`); a
  route through the proxy, which a WebSocket cannot take, stops it with status
  `unavailable` and a notice (`:unreachable`). Past the daily budget the stream
  is closed until the next UTC day and the owner is told once that day
  (`:budget_reached`).

  Status in `cue_sources`: `connected`, `reconnecting`, `auth_failed`,
  `unavailable`. Source telemetry: `connect`, `reconnect`, `disconnect`,
  `auth_failure`, `backfill`, `budget`, `gap`, `stopped`.

  ## Transport

  A transport implements the three callbacks below and sends the owner
  `{:cue_stream, socket, event}` with `event` one of `:connected`,
  `{:frame, {:text | :binary, payload}}` and `:pong`; the socket's exit reason
  says why it ended.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Item
  alias FermixCore.Cues.Jetstream
  alias FermixCore.Cues.Source.Stream.Socket
  alias FermixCore.Cues.Source.Worker

  @preset "bluesky_jetstream"
  @rewind_s 300
  @max_reach_s 86_400
  @max_backfill_items 1_000
  @max_frame_bytes 128 * 1024
  @batch_ms 250
  @batch_items 50
  @heartbeat_ms 30_000
  @stall_ms 90_000
  @first_retry_ms 1_000
  @max_retry_ms 60_000
  @down_notice_ms 900_000
  @handshake_timeout_ms 10_000
  @auth_codes [401, 403]

  @doc "Connects to `url` for `owner`. Options: `:handshake_timeout`, `:egress`."
  @callback start(url :: String.t(), owner :: pid(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}
  @doc "Asks the peer for a pong."
  @callback ping(socket :: pid()) :: :ok
  @doc "Closes the connection; the socket then exits."
  @callback close(socket :: pid()) :: :ok

  @doc """
  Starts the worker for `opts[:source]` (a `Cues.Config.sources/0` map of kind
  `:stream`). Other options, each with a production default: `:repo`, `:clock`
  (zero-arity, a `DateTime`), `:monotonic_ms`, `:schedule` (`(message, ms) ->
  term`), `:transport` (a module with this module's callbacks),
  `:transport_opts` (added to the transport's options), `:admit` (`(ref, n,
  now_ms) -> admitted`, default `Cues.Buckets.admit/3`), `:notify` (default
  `Cues.Notices.source/4`), `:manager` (a pid linked from `init`;
  `Cues.SourceManager` passes itself).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    %{ref: ref, kind: :stream} = Keyword.fetch!(opts, :source)
    true = is_binary(ref)
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    base = Worker.base_state(opts)

    state =
      Map.merge(base, %{
        followed: MapSet.new(Map.get(base.source, :dids, [])),
        transport: Keyword.get(opts, :transport, Socket),
        transport_opts: Keyword.get(opts, :transport_opts, []),
        socket: nil,
        socket_ref: nil,
        closing: nil,
        phase: :idle,
        ever_connected?: false,
        failures: 0,
        resume_at: nil,
        rewind: nil,
        connected_us: nil,
        cursor_us: nil,
        committed_us: nil,
        alive_at: nil,
        caught_up?: false,
        frames_since_beat: 0,
        buffer: [],
        buffered: 0,
        backfilled: 0,
        over_backfill: nil,
        down_since: nil,
        down_notified?: false
      })

    {:ok, Worker.schedule(state, :connect, 0)}
  end

  @impl true
  def handle_info({:timer, kind, token}, state) do
    case Worker.take_timer(state, kind, token) do
      {:due, state} -> on_timer(kind, state)
      :stale -> {:noreply, state}
    end
  end

  # After a batch failed to commit, the connection is closing and nothing more
  # from it is taken (see `accept/3`).
  def handle_info({:cue_stream, _socket, _event}, %{closing: :ingest_failed} = state),
    do: {:noreply, state}

  def handle_info({:cue_stream, socket, event}, %{socket: socket} = state) when is_pid(socket),
    do: on_socket(event, state)

  def handle_info({:cue_stream, _stale_socket, _event}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{socket_ref: ref} = state),
    do: on_down(reason, state)

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # --- timers ----------------------------------------------------------------------

  defp on_timer(:connect, state), do: connect(state, state.clock.())
  defp on_timer(:flush, state), do: {:noreply, flush(state, "connected")}
  defp on_timer(:heartbeat, %{phase: :connected} = state), do: heartbeat(state, state.clock.())
  defp on_timer(:heartbeat, state), do: {:noreply, state}
  defp on_timer(:down, state), do: {:noreply, down_notice(state)}

  # --- connecting --------------------------------------------------------------------

  defp connect(state, now) do
    with :ok <- supported(state.source),
         {:ok, state} <- load(state, now) do
      if Worker.paused?(state, now),
        do: {:noreply, Worker.schedule(state, :connect, Worker.ms_to_next_day(now))},
        else: dial(state, now)
    else
      {:error, :unsupported} -> unsupported(state, now)
      {:error, reason} -> disconnected(state, {:load, reason}, now)
    end
  end

  defp supported(%{preset: @preset}), do: :ok
  defp supported(_source), do: {:error, :unsupported}

  defp dial(state, now) do
    rewind = rewind(state, now)
    source = state.source
    cursor = rewind && DateTime.to_unix(rewind.from, :microsecond)
    url = Jetstream.subscribe_url(source.url, source.dids, source.collections, cursor)
    opts = [handshake_timeout: @handshake_timeout_ms] ++ state.transport_opts

    case state.transport.start(url, self(), opts) do
      {:ok, socket} ->
        monitor = Process.monitor(socket)

        {:noreply,
         %{state | socket: socket, socket_ref: monitor, phase: :connecting, rewind: rewind}}

      {:error, :proxy_unsupported_transport} ->
        proxied(state, now)

      {:error, reason} ->
        disconnected(state, reason, now)
    end
  end

  # Where the next connection resumes: after a read-limit close, at that close;
  # otherwise five minutes before the last good time; a new source at the live
  # tip (nil). Never further back than 24 hours: the rest is a gap.
  defp rewind(state, now) do
    case resume_point(state) do
      nil ->
        nil

      wanted ->
        floor = DateTime.add(now, -@max_reach_s, :second)

        if DateTime.compare(wanted, floor) == :lt,
          do: %{from: floor, reach_gap: {wanted, floor}},
          else: %{from: wanted, reach_gap: nil}
    end
  end

  defp resume_point(%{resume_at: %DateTime{} = at}), do: at
  defp resume_point(%{last_good_at: nil}), do: nil
  defp resume_point(%{last_good_at: good}), do: DateTime.add(good, -@rewind_s, :second)

  defp on_socket(:connected, state) do
    now = state.clock.()
    phase = if state.ever_connected?, do: :reconnect, else: :connect
    Worker.trace(state, phase, %{status: "connected", attempt: state.failures})
    record_rewind(state, now)
    Worker.touch(state, %{status: "connected"}, now)

    state = %{
      state
      | phase: :connected,
        ever_connected?: true,
        failures: 0,
        resume_at: nil,
        down_since: nil,
        down_notified?: false,
        alive_at: now,
        caught_up?: state.rewind == nil,
        frames_since_beat: 0,
        connected_us: DateTime.to_unix(now, :microsecond),
        backfilled: 0
    }

    {:noreply, state |> Worker.drop_timer(:down) |> Worker.schedule(:heartbeat, @heartbeat_ms)}
  end

  defp on_socket(:pong, state), do: {:noreply, %{state | alive_at: state.clock.()}}

  defp on_socket({:frame, {_kind, payload}}, state) when byte_size(payload) > @max_frame_bytes,
    do: {:noreply, too_large(state, state.clock.())}

  defp on_socket({:frame, {:text, text}}, state) do
    now = state.clock.()
    decoded(Jetstream.decode(text, state.followed), framed(state, now), now)
  end

  defp on_socket({:frame, {:binary, _payload}}, state) do
    entry = {:error, {:invalid, "The stream sent a binary frame, which Jetstream does not use."}}
    {:noreply, buffer(framed(state, state.clock.()), entry, nil)}
  end

  defp framed(state, now),
    do: %{state | alive_at: now, frames_since_beat: state.frames_since_beat + 1}

  defp record_rewind(%{rewind: nil}, _now), do: :ok

  defp record_rewind(%{rewind: rewind} = state, now) do
    Worker.trace(state, :backfill, %{
      duration_ms: max(DateTime.diff(now, rewind.from, :millisecond), 0)
    })

    case rewind.reach_gap do
      nil -> :ok
      range -> Worker.gap(state, "disconnect", 1, range, now)
    end
  end

  # --- frames --------------------------------------------------------------------------

  defp decoded({:item, fields, time_us}, state, now),
    do: {:noreply, buffer(state, fields |> Item.new(now) |> Worker.unwrap(), time_us)}

  defp decoded({:skip, {:info, "OutdatedCursor"}, nil}, state, now) do
    from = state.rewind && state.rewind.from
    Worker.gap(state, "disconnect", 1, {from, nil}, now)
    {:noreply, state}
  end

  defp decoded({:skip, _reason, time_us}, state, _now), do: {:noreply, seen(state, time_us)}
  defp decoded({:error, :frame_too_large}, state, now), do: {:noreply, too_large(state, now)}

  defp decoded({:error, {:stream_error, name}}, state, _now) do
    Logger.warning("Cue stream #{state.source.ref}: the service ended the stream (#{name})")
    {:noreply, close_socket(state, :stream_error)}
  end

  defp decoded({:error, reason}, state, _now) do
    entry =
      {:error, {:invalid, "The stream sent a frame that is not a Jetstream event (#{reason})."}}

    {:noreply, buffer(state, entry, nil)}
  end

  defp buffer(state, entry, time_us) do
    state = seen(state, time_us)
    backfill? = backfill?(state, time_us)

    cond do
      backfill? and state.backfilled >= @max_backfill_items ->
        over_backfill(state, time_us)

      state.buffered + 1 >= @batch_items ->
        state |> push(entry, backfill?) |> flush("connected")

      true ->
        state |> push(entry, backfill?) |> arm_flush()
    end
  end

  defp push(state, entry, backfill?) do
    %{
      state
      | buffer: [entry | state.buffer],
        buffered: state.buffered + 1,
        backfilled: state.backfilled + if(backfill?, do: 1, else: 0)
    }
  end

  # `Cues.Ingest.accept/3` takes an item, or the refusal `Item.new/2` returned.

  defp backfill?(%{connected_us: connected}, time_us)
       when is_integer(connected) and is_integer(time_us),
       do: time_us < connected

  defp backfill?(_state, _time_us), do: false

  # An event from after the connection opened ends the backfill.
  defp seen(state, time_us) when is_integer(time_us) do
    caught_up? = state.caught_up? or not backfill?(state, time_us)
    %{state | cursor_us: max(state.cursor_us || time_us, time_us), caught_up?: caught_up?}
  end

  defp seen(state, nil), do: state

  defp over_backfill(state, time_us) do
    over = state.over_backfill || %{count: 0, from_us: time_us, to_us: time_us}

    over = %{
      count: over.count + 1,
      from_us: min(over.from_us, time_us),
      to_us: max(over.to_us, time_us)
    }

    %{state | over_backfill: over}
  end

  defp arm_flush(state) do
    if Map.has_key?(state.timers, :flush),
      do: state,
      else: Worker.schedule(state, :flush, @batch_ms)
  end

  # --- accepting -----------------------------------------------------------------------

  # Accepts everything waiting, with the last good time it covers, in one
  # transaction. On a failed transaction the connection is dropped: the next
  # one rewinds from the last good time written, so the items come again. Until
  # that drop lands, the connection writes nothing more (no heartbeat, no flush
  # at the drop), and the newest event time seen goes back to the one last
  # committed: either would carry the failed batch's progress into
  # `last_good_at` and resume past items that were never stored.
  defp flush(%{closing: :ingest_failed} = state, _status), do: state

  defp flush(state, status) do
    now = state.clock.()
    state = state |> Worker.drop_timer(:flush) |> write_over_backfill(now)

    if state.buffer == [] and not advanced?(state),
      do: state,
      else: accept(state, status, now)
  end

  defp accept(state, status, now) do
    covered = covered_at(state)
    source_state = %{cursor: cursor_text(state.cursor_us), last_good_at: covered, status: status}

    opts = [
      now: now,
      repo: state.repo,
      admit: Worker.admit_fun(state),
      source_state: source_state
    ]

    entries = Enum.reverse(state.buffer)
    state = %{state | buffer: [], buffered: 0}

    case Ingest.accept(Worker.ingest_source(state), entries, opts) do
      {:ok, results} ->
        state = %{
          state
          | last_good_at: later(state.last_good_at, covered),
            committed_us: state.cursor_us
        }

        if :over_budget in results, do: budget_reached(state, now), else: state

      {:error, _traced} ->
        close_socket(%{state | cursor_us: state.committed_us}, :ingest_failed)
    end
  end

  defp advanced?(state) do
    case covered_at(state) do
      nil -> false
      covered -> state.last_good_at == nil or DateTime.compare(covered, state.last_good_at) == :gt
    end
  end

  # How far the received stream is known complete. Live, that is the last frame
  # or pong. During a backfill the service replays in time order, so it is the
  # newest event time seen (never past the last frame): a drop mid-replay then
  # resumes where the replay got to, not at the wall clock.
  defp covered_at(%{caught_up?: true} = state), do: state.alive_at
  defp covered_at(%{cursor_us: nil}), do: nil
  defp covered_at(state), do: earlier(from_us(state.cursor_us), state.alive_at)

  defp earlier(at, nil), do: at
  defp earlier(at, other), do: if(DateTime.compare(at, other) == :gt, do: other, else: at)

  defp later(nil, at), do: at
  defp later(at, nil), do: at
  defp later(at, other), do: if(DateTime.compare(at, other) == :lt, do: other, else: at)

  defp write_over_backfill(%{over_backfill: nil} = state, _now), do: state

  defp write_over_backfill(%{over_backfill: over} = state, now) do
    range = {from_us(over.from_us), from_us(over.to_us)}
    Worker.gap(state, "backfill_limit", over.count, range, now)
    %{state | over_backfill: nil}
  end

  defp cursor_text(nil), do: nil
  defp cursor_text(time_us), do: Integer.to_string(time_us)

  defp from_us(time_us), do: DateTime.from_unix!(time_us, :microsecond)

  # --- liveness and limits -------------------------------------------------------------

  defp heartbeat(state, now) do
    if DateTime.diff(now, state.alive_at, :millisecond) > @stall_ms do
      Logger.warning("Cue stream #{state.source.ref}: no frame or pong for 90 s; reconnecting")
      {:noreply, close_socket(state, :stalled)}
    else
      state.transport.ping(state.socket)
      state = %{state | caught_up?: state.caught_up? or state.frames_since_beat == 0}
      state = %{state | frames_since_beat: 0}
      {:noreply, state |> flush("connected") |> Worker.schedule(:heartbeat, @heartbeat_ms)}
    end
  end

  # The frame's own time is unknown (it is not decoded), so the next connection
  # resumes at this close and the gap's range runs from what was known complete
  # to now: a replay in progress loses the rest of its window, inside that range.
  defp too_large(state, now) do
    from = covered_at(state) || now
    state = flush(state, "connected")

    # A flush that failed has closed the connection to replay from the last
    # good time; resuming at this close would skip what it lost.
    if state.closing == :ingest_failed do
      state
    else
      Worker.gap(state, "read_limit", 1, {from, now}, now)
      close_socket(%{state | resume_at: now}, :read_limit)
    end
  end

  defp close_socket(%{socket: nil} = state, _reason), do: state
  defp close_socket(%{closing: :ingest_failed} = state, _reason), do: state

  defp close_socket(state, reason) do
    state.transport.close(state.socket)
    %{state | closing: reason}
  end

  # --- disconnects -----------------------------------------------------------------------

  # What was received before the drop is accepted first. A flush that spent the
  # daily budget has paused the stream already: that drop is no outage.
  defp on_down(reason, state) do
    now = state.clock.()
    closing = state.closing
    state = state |> flush("reconnecting") |> forget_socket()

    cond do
      state.phase == :paused -> {:noreply, state}
      auth_refused?(reason) -> auth_failed(state, now)
      true -> disconnected(state, closing || reason, now)
    end
  end

  defp forget_socket(state) do
    state = %{state | socket: nil, socket_ref: nil, closing: nil, connected_us: nil}
    Worker.drop_timer(state, :heartbeat)
  end

  defp auth_refused?({:error, %WebSockex.RequestError{code: code}}), do: code in @auth_codes
  defp auth_refused?(%WebSockex.RequestError{code: code}), do: code in @auth_codes
  defp auth_refused?(_reason), do: false

  defp disconnected(state, reason, now) do
    failures = state.failures + 1
    label = down_label(reason)

    Worker.trace(state, :disconnect, %{
      status: "reconnecting",
      reason: label,
      attempt: failures,
      result: {:error, label}
    })

    Logger.warning(
      "Cue stream #{state.source.ref} disconnected (#{inspect(reason)}); attempt #{failures}"
    )

    state = %{state | failures: failures, phase: :waiting}
    state = if state.down_since, do: state, else: start_outage(state, now)
    {:noreply, Worker.schedule(state, :connect, retry_ms(failures))}
  end

  defp start_outage(state, now) do
    Worker.touch(state, %{status: "reconnecting"}, now)
    state = %{state | down_since: now, down_notified?: false}
    Worker.schedule(state, :down, down_notice_ms(state, now))
  end

  # The owner hears of an outage once it is longer than 15 minutes and longer
  # than a reconnect could still replay (the 24 hours behind the resume point),
  # so the notice is true when it says the rest is a gap. A source that never
  # had a good time has nothing to replay: 15 minutes.
  defp down_notice_ms(state, now) do
    case resume_point(state) do
      nil ->
        @down_notice_ms

      resume ->
        lost_at = DateTime.add(resume, @max_reach_s, :second)
        max(@down_notice_ms, DateTime.diff(lost_at, now, :millisecond))
    end
  end

  defp down_notice(%{phase: :connected} = state), do: state
  defp down_notice(%{down_notified?: true} = state), do: state
  defp down_notice(%{down_since: nil} = state), do: state

  defp down_notice(state) do
    Worker.notify(state, :down, %{since: DateTime.to_iso8601(state.down_since)}, state.clock.())
    %{state | down_notified?: true}
  end

  defp auth_failed(state, now) do
    Worker.trace(state, :auth_failure, %{status: "auth_failed", result: {:error, :auth_refused}})
    Worker.touch(state, %{status: "auth_failed"}, now)
    Logger.error("Cue stream #{state.source.ref}: the service refused the credential; stopped")
    Worker.notify(state, :auth_failed, %{}, now)
    stop(state, "auth_failed", :auth_refused)
  end

  defp proxied(state, now) do
    Worker.touch(state, %{status: "unavailable"}, now)

    Logger.error(
      "Cue stream #{state.source.ref} is not connected: a WebSocket cannot use the outbound " <>
        "proxy. List its host in [fermix_core.network] proxy_bypass if this machine reaches it " <>
        "directly; the source starts again when its settings change."
    )

    Worker.notify(state, :unreachable, %{reason: "proxy_unsupported_transport"}, now)
    stop(state, "unavailable", :proxy_unsupported_transport)
  end

  defp unsupported(state, now) do
    Worker.touch(state, %{status: "unavailable"}, now)

    Logger.error(
      "Cue stream #{state.source.ref} has no worker for its settings: only the " <>
        "#{@preset} preset is streamed"
    )

    stop(state, "unavailable", :unsupported_preset)
  end

  defp stop(state, status, reason) do
    Worker.trace(state, :stopped, %{status: status, reason: reason, result: {:error, reason}})
    {:stop, :normal, state}
  end

  defp retry_ms(failures), do: Worker.backoff_ms(failures, @first_retry_ms, @max_retry_ms)

  # A short label for the trace; the whole reason goes to the log.
  defp down_label(reason) when reason in [:read_limit, :stalled, :stream_error, :ingest_failed],
    do: reason

  defp down_label({:load, _reason}), do: :repo
  defp down_label({:remote, _detail}), do: :remote_closed
  defp down_label({:remote, _code, _message}), do: :remote_closed
  defp down_label({:error, %WebSockex.RequestError{}}), do: :handshake_refused
  defp down_label({:error, %WebSockex.ConnError{}}), do: :connect_failed
  defp down_label(:ws_url_without_host), do: :ws_url_without_host
  defp down_label(_reason), do: :socket_down

  # --- budget ----------------------------------------------------------------------------

  defp budget_reached(state, now) do
    state = Worker.budget_reached(state, now)

    # Forget the socket before closing it: its exit is no outage.
    if state.socket_ref, do: Process.demonitor(state.socket_ref, [:flush])
    if state.socket, do: state.transport.close(state.socket)

    %{state | socket: nil, socket_ref: nil, phase: :paused}
    |> Worker.drop_timer(:heartbeat)
    |> Worker.schedule(:connect, Worker.ms_to_next_day(now))
  end

  # --- the source's row ------------------------------------------------------------------

  defp load(state, now) do
    with {:ok, state, _row} <- Worker.load(state, now), do: {:ok, state}
  end
end
