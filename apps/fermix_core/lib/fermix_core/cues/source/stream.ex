defmodule FermixCore.Cues.Source.Stream do
  @moduledoc """
  One stream source's connection (M60 §6.3, §6.9, §6.10, and the WebSocket
  source design). The preset chooses the reader, in `reader/1` and nowhere
  else: `bluesky_jetstream` reads Bluesky's public Jetstream (`Cues.Jetstream`),
  which rewinds with a cursor; a stream with no preset is the general
  WebSocket source (`Cues.JsonStream`), which signs in with the owner's key
  and secret, takes each message of an item type, and cannot rewind.
  Connecting, batches, the heartbeat, the budget, backoff and notices are the
  same for both.

  The worker owns a transport process (`Cues.Source.Stream.Socket` in
  production; the contract is `Cues.Source.Stream.Transport`), monitors it,
  and keeps everything that must survive a reconnect itself: the last good
  time, the backoff, the batch, the refusal count. It acknowledges each frame
  once it has handled it, and gives the transport its reader's frame cap.

  **Signing in** (no preset). The secrets the sign-in names are read from
  their store once per connection, when dialling, and kept in no state: the
  sign-in headers, and the sign-in message and the message after connecting
  (sent in that order as soon as the upgrade completes, with no wait for a
  reply), are built then and handed to the transport. No secret, and no
  message after its placeholders are filled, is logged, traced or written to
  the source's row.

  **A healthy connection.** An upgrade alone proves nothing: a service may
  accept the connection and then refuse it (a lingering session, a bad key).
  A connection proves healthy at its first item, or at the first heartbeat
  that finds it alive (30 seconds); only then is the outage over, the backoff
  and the refusal count reset, and the source's row `connected`. Until then a
  source that keeps being refused shows `reconnecting` and backs off.

  **Cursor and backfill** (Jetstream). `cue_sources.last_good_at` is the local
  time the connection was last known good, written in the same transaction as
  the cues it covers (a frame or a pong is the evidence; a heartbeat writes it
  when no item came). While a reconnect is still replaying, the evidence is the
  newest event time seen instead, so a drop mid-replay resumes where the replay
  got to; the replay is over at the first event from after the connection
  opened, or at a heartbeat with no frame since the last. A reconnect resumes
  from the last good time minus 5 minutes, in unix microseconds, reaching back
  at most 24 hours: anything older is a `disconnect` gap with its range, and so
  is an `OutdatedCursor` notice from the service (it clamped the resume
  point). A new source starts at the live tip. Backfilled items beyond 1,000
  per connection are a `backfill_limit` gap. Repeats are duplicates by
  identity. `cue_sources.cursor` holds the newest event time seen, for reading
  only. The general source has no cursor: what the service sends while it is
  disconnected is missed, and no gap is recorded for it, since its size is
  unknown.

  **Batches.** Items are accepted every 250 ms, or at once when 50 are waiting,
  through `Cues.Ingest.accept/3` with the rate buckets (`Cues.Buckets.admit/3`)
  and `status: "connected"`.

  **Limits.** A frame over the reader's cap (128 KiB for Jetstream, 1 MiB for
  the general source) closes the connection with a `read_limit` gap, whether
  the reader refuses it or the transport ends the connection before it is
  whole (`:frame_too_large`), and the next connection resumes from the time of
  that close, so the same frame is not replayed; the gap's range runs from
  what was known complete to the close. A general frame of more than 100
  messages keeps the first 100 and records the rest as a `page_limit` gap. A
  connection silent past 90 seconds (no frame, no answer to the 30-second
  ping) is closed and dialled again.

  **Failures.** Reconnects back off from one second doubling to a minute, and
  never stop. The owner is told of an outage once (`:down`) when it is longer
  than 15 minutes and longer than a reconnect could still replay (24 hours back
  from the resume point; a source that never had a good time, or whose reader
  cannot rewind, has nothing to replay). A refused credential (HTTP 401 or 403
  at the upgrade) stops the worker with status `auth_failed` and a notice
  (`:auth_failed`); a route through the proxy, which a WebSocket cannot take,
  or a host that resolves to an address `Net.Guard` refuses, stops it with
  status `unavailable` and a notice (`:unreachable`). An error message from
  the general source's service (a type in `error_types`) closes the
  connection; one from a connection that delivered no item is a refusal, a
  healthy connection resets the count, and the eighth refusal in a row stops
  the worker with status `stopped` and a notice (`:refused`). The service's words go to the
  log and the trace (behind the content gate) only. Past the daily budget the
  stream is closed until the next UTC day and the owner is told once that day
  (`:budget_reached`).

  Status in `cue_sources`: `connected`, `reconnecting`, `auth_failed`,
  `unavailable`, `stopped`. Source telemetry: `connect`, `reconnect`,
  `disconnect` (`reason: :service_error` for a service's error), `auth_failure`,
  `backfill`, `budget`, `gap`, `stopped` (`reason: :refused` after the eighth
  refusal).
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Item
  alias FermixCore.Cues.Jetstream
  alias FermixCore.Cues.JsonStream
  alias FermixCore.Cues.Source.Stream.Socket
  alias FermixCore.Cues.Source.Worker
  alias FermixCore.Setup.SecretWriter

  @rewind_s 300
  @max_reach_s 86_400
  @max_backfill_items 1_000
  @batch_ms 250
  @batch_items 50
  @heartbeat_ms 30_000
  @stall_ms 90_000
  @first_retry_ms 1_000
  @max_retry_ms 60_000
  @down_notice_ms 900_000
  @handshake_timeout_ms 10_000
  @auth_codes [401, 403]
  # The general source stops at the eighth connection in a row that ended on
  # the service's error before any item, as a feed stops at its eighth failure.
  @max_refusals 8

  @doc """
  Starts the worker for `opts[:source]` (a `Cues.Config.sources/0` map of kind
  `:stream`). Other options, each with a production default: `:repo`, `:clock`
  (zero-arity, a `DateTime`), `:monotonic_ms`, `:schedule` (`(message, ms) ->
  term`), `:transport` (a module with this module's callbacks),
  `:transport_opts` (added to the transport's options), `:admit` (`(ref, n,
  now_ms) -> admitted`, default `Cues.Buckets.admit/3`), `:notify` (default
  `Cues.Notices.source/4`), `:manager` (a pid linked from `init`;
  `Cues.SourceManager` passes itself). A transport implements
  `Cues.Source.Stream.Transport`.
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
        reader: reader(base.source),
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
        down_notified?: false,
        refusals: 0,
        delivered?: false,
        healthy?: false
      })

    {:ok, Worker.schedule(state, :connect, 0)}
  end

  # The reader of the stream's frames, chosen by its preset here and nowhere
  # else: Bluesky's Jetstream, which rewinds with a cursor, or the general JSON
  # reader, which cannot.
  defp reader(%{preset: "bluesky_jetstream"}), do: Jetstream
  defp reader(%{preset: nil}), do: JsonStream

  @impl true
  def handle_info({:timer, kind, token}, state) do
    case Worker.take_timer(state, kind, token) do
      {:due, state} -> on_timer(kind, state)
      :stale -> {:noreply, state}
    end
  end

  # After a batch failed to commit, the connection is closing and nothing more
  # from it is taken (see `accept/3`). Every frame is acknowledged once handled,
  # so the transport reads on.
  def handle_info({:cue_stream, socket, event}, %{socket: socket} = state) when is_pid(socket) do
    reply =
      if state.closing == :ingest_failed, do: {:noreply, state}, else: on_socket(event, state)

    if match?({:frame, _frame}, event), do: state.transport.ack(socket)
    reply
  end

  def handle_info({:cue_stream, _stale_socket, _event}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{socket_ref: ref} = state),
    do: on_down(reason, state)

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # --- timers ----------------------------------------------------------------------

  defp on_timer(:connect, state), do: connect(state, state.clock.())
  # A batch is taken only on a live connection; what waits after a drop is
  # accepted by the next connection's first flush.
  defp on_timer(:flush, %{phase: :connected, closing: nil} = state),
    do: {:noreply, flush(state, live_status(state))}

  defp on_timer(:flush, state), do: {:noreply, state}
  # A closing connection has no heartbeat: its close is bounded by the transport.
  defp on_timer(:heartbeat, %{phase: :connected, closing: nil} = state),
    do: heartbeat(state, state.clock.())

  defp on_timer(:heartbeat, state), do: {:noreply, state}
  defp on_timer(:down, state), do: {:noreply, down_notice(state)}

  # --- connecting --------------------------------------------------------------------

  defp connect(state, now) do
    case load(state, now) do
      {:ok, state} ->
        if Worker.paused?(state, now),
          do: {:noreply, Worker.schedule(state, :connect, Worker.ms_to_next_day(now))},
          else: dial(state, now)

      {:error, reason} ->
        disconnected(state, {:load, reason}, now)
    end
  end

  defp dial(state, now) do
    rewind = rewind(state, now)

    case sign_in(state, rewind) do
      {:ok, url, plan} -> start_socket(state, url, plan, rewind, now)
      {:error, reason} -> disconnected(state, reason, now)
    end
  end

  # Where to connect and how to sign in: Jetstream's subscribe URL at the
  # resume point, with neither headers nor messages; or the general source's
  # address with its sign-in headers and messages, built from the secrets as
  # they are stored now (one read per connection) and kept in no state. A
  # secret that cannot be read, or cannot be sent, is a disconnect before
  # dialling.
  defp sign_in(%{reader: Jetstream, source: source}, rewind) do
    cursor = rewind && DateTime.to_unix(rewind.from, :microsecond)
    url = Jetstream.subscribe_url(source.url, source.dids, source.collections, cursor)
    {:ok, url, %{headers: [], messages: []}}
  end

  defp sign_in(%{reader: JsonStream, source: source}, _rewind) do
    with {:ok, secrets} <- read_secrets(source),
         {:ok, headers} <- JsonStream.headers(source, secrets),
         {:ok, messages} <- JsonStream.messages(source, secrets) do
      {:ok, source.url, %{headers: headers, messages: messages}}
    end
  end

  # The secrets the sign-in names, from the stores their sentinels name. An
  # error names the field and the store's reason, never a value.
  defp read_secrets(source) do
    source
    |> JsonStream.secret_fields()
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, acc} ->
      case read_secret(source, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, reason} -> {:halt, {:error, {:secret, field, reason}}}
      end
    end)
  end

  defp read_secret(%{ref: ref, secrets: stores}, field) do
    case Map.fetch(stores, field) do
      {:ok, store} -> SecretWriter.get({:cue_source, ref, field}, store: store)
      :error -> {:error, :not_configured}
    end
  end

  defp start_socket(state, url, plan, rewind, now) do
    opts =
      [
        handshake_timeout: @handshake_timeout_ms,
        headers: plan.headers,
        messages: plan.messages,
        max_frame_bytes: state.reader.max_frame_bytes()
      ] ++ state.transport_opts

    # The transport took the monitor in this process before returning, so its
    # exit cannot come unwatched.
    case state.transport.start(url, self(), opts) do
      {:ok, socket, monitor} ->
        {:noreply,
         %{state | socket: socket, socket_ref: monitor, phase: :connecting, rewind: rewind}}

      {:error, :proxy_unsupported_transport} ->
        proxied(state, now)

      {:error, reason} ->
        disconnected(state, reason, now)
    end
  end

  # Where the next connection resumes: after a read-limit close, at that close;
  # otherwise five minutes before the last good time; a new source, or a reader
  # that cannot rewind, at the live tip (nil). Never further back than 24
  # hours: the rest is a gap.
  defp rewind(state, now) do
    case replay_from(state) do
      nil ->
        nil

      wanted ->
        floor = DateTime.add(now, -@max_reach_s, :second)

        if DateTime.compare(wanted, floor) == :lt,
          do: %{from: floor, reach_gap: {wanted, floor}},
          else: %{from: wanted, reach_gap: nil}
    end
  end

  defp replay_from(state), do: if(state.reader.rewinds?(), do: resume_point(state))

  defp resume_point(%{resume_at: %DateTime{} = at}), do: at
  defp resume_point(%{last_good_at: nil}), do: nil
  defp resume_point(%{last_good_at: good}), do: DateTime.add(good, -@rewind_s, :second)

  # The upgrade is traced, but proves nothing yet (`healthy/2`): the outage,
  # the backoff and the refusal count stand until the connection does.
  defp on_socket(:connected, state) do
    now = state.clock.()
    phase = if state.ever_connected?, do: :reconnect, else: :connect
    Worker.trace(state, phase, %{status: "connected", attempt: state.failures})
    record_rewind(state, now)

    state = %{
      state
      | phase: :connected,
        ever_connected?: true,
        resume_at: nil,
        alive_at: now,
        caught_up?: state.rewind == nil,
        frames_since_beat: 0,
        connected_us: DateTime.to_unix(now, :microsecond),
        backfilled: 0,
        delivered?: false,
        healthy?: false
    }

    {:noreply, Worker.schedule(state, :heartbeat, @heartbeat_ms)}
  end

  defp on_socket(:pong, state), do: {:noreply, %{state | alive_at: state.clock.()}}

  # Each reader refuses a frame over its own cap before the frame counts as
  # evidence the connection is alive.
  defp on_socket({:frame, {:text, text}}, %{reader: Jetstream} = state) do
    now = state.clock.()

    case Jetstream.decode(text, state.followed) do
      {:error, :frame_too_large} -> {:noreply, too_large(state, now)}
      decoded -> decoded(decoded, framed(state, now), now)
    end
  end

  defp on_socket({:frame, {:binary, _payload}}, %{reader: Jetstream} = state) do
    entry = {:error, {:invalid, "The stream sent a binary frame, which Jetstream does not use."}}
    {:noreply, buffer(framed(state, state.clock.()), entry, nil)}
  end

  defp on_socket({:frame, frame}, %{reader: JsonStream} = state) do
    now = state.clock.()

    case JsonStream.read(frame, state.source) do
      {:ok, read} -> {:noreply, json_read(framed(state, now), read, now)}
      {:error, :frame_too_large} -> {:noreply, too_large(state, now)}
    end
  end

  defp framed(state, now),
    do: %{state | alive_at: now, frames_since_beat: state.frames_since_beat + 1}

  # A connection proves healthy at its first item, or at the first heartbeat
  # that finds it alive; not at its first frame, since a service may greet a
  # connection and then refuse it. Only then is the outage over, the backoff
  # and the refusal count reset, and the source's row `connected`. A connection
  # Fermix is closing never proves healthy, even with an item after its error.
  defp healthy(%{healthy?: true} = state, _now), do: state
  defp healthy(%{closing: closing} = state, _now) when closing != nil, do: state

  defp healthy(state, now) do
    Worker.touch(state, %{status: "connected"}, now)

    %{state | healthy?: true, failures: 0, refusals: 0, down_since: nil, down_notified?: false}
    |> Worker.drop_timer(:down)
  end

  # The status a batch writes: `connected` once the connection is healthy;
  # before that the row keeps what it says (nil leaves the column as it is).
  defp live_status(%{healthy?: true}), do: "connected"
  defp live_status(_state), do: nil

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

  defp decoded({:item, fields, time_us}, state, now) do
    entry = fields |> Item.new(now) |> Worker.unwrap()
    {:noreply, buffer(healthy(state, now), entry, time_us)}
  end

  defp decoded({:skip, {:info, "OutdatedCursor"}, nil}, state, now) do
    from = state.rewind && state.rewind.from
    Worker.gap(state, "disconnect", 1, {from, nil}, now)
    {:noreply, state}
  end

  defp decoded({:skip, _reason, time_us}, state, _now), do: {:noreply, seen(state, time_us)}

  defp decoded({:error, {:stream_error, name}}, state, _now) do
    Logger.warning("Cue stream #{state.source.ref}: the service ended the stream (#{name})")
    {:noreply, close_socket(state, :stream_error)}
  end

  defp decoded({:error, reason}, state, _now) do
    entry =
      {:error, {:invalid, "The stream sent a frame that is not a Jetstream event (#{reason})."}}

    {:noreply, buffer(state, entry, nil)}
  end

  # A general frame's messages, in order. More than 100 is a `page_limit` gap
  # for the rest; an item proves the connection healthy.
  defp json_read(state, %{entries: entries, over_limit: over}, now) do
    if over > 0, do: Worker.gap(state, "page_limit", over, {now, now}, now)
    Enum.reduce(entries, state, &json_entry(&1, &2, now))
  end

  defp json_entry({:item, fields}, state, now) do
    state = %{healthy(state, now) | delivered?: true}
    buffer(state, fields |> Item.new(now) |> Worker.unwrap(), nil)
  end

  defp json_entry({:reject, sentence}, state, _now),
    do: buffer(state, {:error, {:invalid, sentence}}, nil)

  defp json_entry({:service_error, words}, state, _now), do: service_error(state, words)

  defp json_entry(:skip, state, _now) do
    Logger.debug("Cue stream #{state.source.ref}: skipped a message that is not an item")
    state
  end

  # The service's error closes the connection. The first one a connection
  # sends is a refusal unless that connection delivered an item; the words
  # reach the log and the trace when the connection is down.
  defp service_error(%{closing: nil} = state, words) do
    refusals = if state.delivered?, do: 0, else: state.refusals + 1
    close_socket(%{state | refusals: refusals}, {:service_error, words})
  end

  defp service_error(state, words) do
    Logger.warning("Cue stream #{state.source.ref}: the service sent another error (#{words})")
    state
  end

  defp buffer(state, entry, time_us) do
    state = seen(state, time_us)
    backfill? = backfill?(state, time_us)

    cond do
      backfill? and state.backfilled >= @max_backfill_items ->
        over_backfill(state, time_us)

      state.buffered + 1 >= @batch_items ->
        state |> push(entry, backfill?) |> flush(live_status(state))

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
      state = healthy(%{state | frames_since_beat: 0}, now)
      {:noreply, state |> flush(live_status(state)) |> Worker.schedule(:heartbeat, @heartbeat_ms)}
    end
  end

  # The frame's own time is unknown (it is not decoded), so the next connection
  # resumes at this close and the gap's range runs from what was known complete
  # to now: a replay in progress loses the rest of its window, inside that range.
  # The same holds when the transport ended the connection at such a frame
  # (`read_limit_down/3`).
  defp too_large(state, now) do
    from = covered_at(state) || now
    state = flush(state, live_status(state))

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
  # daily budget has paused the stream already: that drop is no outage. A
  # failed flush (now or before) means a replay from the last good time.
  defp on_down(reason, state) do
    now = state.clock.()
    closing = state.closing
    from = covered_at(state) || now
    state = flush(state, "reconnecting")
    replay? = state.closing == :ingest_failed
    state = forget_socket(state)

    ended(reason, closing, %{from: from, replay?: replay?}, state, now)
  end

  defp ended(_reason, _closing, _ctx, %{phase: :paused} = state, _now), do: {:noreply, state}

  defp ended({:upgrade_refused, status}, _closing, _ctx, state, now) when status in @auth_codes,
    do: auth_failed(state, now)

  defp ended(:address_refused, _closing, _ctx, state, now), do: address_refused(state, now)
  defp ended(:frame_too_large, _closing, ctx, state, now), do: read_limit_down(state, ctx, now)

  defp ended(_reason, {:service_error, words}, _ctx, %{refusals: n} = state, now)
       when n >= @max_refusals,
       do: refused(state, words, now)

  defp ended(reason, closing, _ctx, state, now), do: disconnected(state, closing || reason, now)

  # The transport ended the connection at a frame over the cap, before it was
  # whole: a `read_limit` gap, and the next connection resumes at this close,
  # unless a lost batch must be replayed from the last good time first.
  defp read_limit_down(state, %{replay?: true}, now),
    do: disconnected(state, :ingest_failed, now)

  defp read_limit_down(state, %{from: from}, now) do
    Worker.gap(state, "read_limit", 1, {from, now}, now)
    disconnected(%{state | resume_at: now}, :read_limit, now)
  end

  # A batch timer of the dropped connection goes with it: what still waits is
  # taken by the next connection's first flush.
  defp forget_socket(state) do
    %{state | socket: nil, socket_ref: nil, closing: nil, connected_us: nil, healthy?: false}
    |> Worker.drop_timer(:heartbeat)
    |> Worker.drop_timer(:flush)
  end

  defp disconnected(state, reason, now) do
    failures = state.failures + 1
    label = down_label(reason)

    Worker.trace(
      state,
      :disconnect,
      Map.merge(
        %{status: "reconnecting", reason: label, attempt: failures, result: {:error, label}},
        service_words(reason)
      )
    )

    Logger.warning(
      "Cue stream #{state.source.ref} disconnected (#{loggable(reason)}); attempt #{failures}"
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
  # had a good time, or whose reader cannot rewind, has nothing to replay: 15
  # minutes.
  defp down_notice_ms(state, now) do
    case replay_from(state) do
      nil ->
        @down_notice_ms

      resume ->
        lost_at = DateTime.add(resume, @max_reach_s, :second)
        max(@down_notice_ms, DateTime.diff(lost_at, now, :millisecond))
    end
  end

  defp down_notice(%{healthy?: true} = state), do: state
  defp down_notice(%{down_notified?: true} = state), do: state
  defp down_notice(%{down_since: nil} = state), do: state

  defp down_notice(state) do
    data = %{since: DateTime.to_iso8601(state.down_since), catch_up: state.reader.rewinds?()}
    Worker.notify(state, :down, data, state.clock.())
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

  defp address_refused(state, now) do
    Worker.touch(state, %{status: "unavailable"}, now)

    Logger.error(
      "Cue stream #{state.source.ref} is not connected: its host resolves to a private, " <>
        "loopback or link-local address, which Fermix does not connect to; the source starts " <>
        "again when its settings change."
    )

    Worker.notify(state, :unreachable, %{reason: "address_refused"}, now)
    stop(state, "unavailable", :address_refused)
  end

  # The eighth connection in a row that ended on the service's error with no
  # item: a held connection or a refused key, which reconnecting will not fix.
  defp refused(state, words, now) do
    Worker.touch(state, %{status: "stopped"}, now)

    Logger.error(
      "Cue stream #{state.source.ref}: the service sent an error each of the last " <>
        "#{@max_refusals} times Fermix connected, with no item (last: #{words}); stopped"
    )

    Worker.notify(state, :refused, %{}, now)
    stop(state, "stopped", :refused, %{content: words})
  end

  defp stop(state, status, reason, extra \\ %{}) do
    metadata = %{status: status, reason: reason, result: {:error, reason}}
    Worker.trace(state, :stopped, Map.merge(metadata, extra))
    {:stop, :normal, state}
  end

  defp retry_ms(failures), do: Worker.backoff_ms(failures, @first_retry_ms, @max_retry_ms)

  # A short label for the trace; the whole reason goes to the log. The
  # service's own words ride the trace behind the content gate.
  defp down_label(reason)
       when reason in [:read_limit, :stalled, :stream_error, :ingest_failed, :url_without_host],
       do: reason

  defp down_label({:service_error, _words}), do: :service_error
  defp down_label({:load, _reason}), do: :repo
  defp down_label({:secret, _field, _reason}), do: :secret_unavailable
  defp down_label({:unsendable_secret, _field}), do: :secret_unsendable
  defp down_label({:remote_closed, _code}), do: :remote_closed
  defp down_label({:upgrade_refused, _status}), do: :handshake_refused
  defp down_label({:connect_failed, _reason}), do: :connect_failed
  defp down_label(_reason), do: :socket_down

  defp service_words({:service_error, words}), do: %{content: words}
  defp service_words(_reason), do: %{}

  # A crashed transport's exit carries its stacktrace, whose arguments could
  # hold a sign-in header: it is logged as its error's banner, never whole.
  defp loggable({error, [{module, _fun, _args, _location} | _rest] = stacktrace})
       when is_atom(module),
       do: Exception.format_banner(:error, error, stacktrace)

  defp loggable(reason), do: inspect(reason)

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
