defmodule FermixCore.Cues.Source.Stream do
  @moduledoc """
  One stream source's connection (M60 §6.3, §6.9, §6.10, and the WebSocket
  source design). A stream is the general WebSocket source, read by
  `Cues.JsonStream`: it signs in with the owner's key and secret, takes each
  message of an item type, and cannot rewind.

  The worker owns a transport process (`Cues.Source.Stream.Socket` in
  production; the contract is `Cues.Source.Stream.Transport`), monitors it,
  and keeps everything that must survive a reconnect itself: the last good
  time, the backoff, the counts, the refusal count. It acknowledges each frame
  once it has handled it, and gives the transport the reader's frame cap.

  **Signing in.** The secrets the sign-in names are read from their store
  once per connection, when dialling, and kept in no state: the sign-in
  headers, and the sign-in message and the message after connecting (sent in
  that order as soon as the upgrade completes, with no wait for a reply), are
  built then and handed to the transport. No secret, and no message after its
  placeholders are filled, is logged, traced or written to the source's row.

  **A healthy connection.** An upgrade alone proves nothing: a service may
  accept the connection and then refuse it (a lingering session, a bad key).
  A connection proves healthy at its first item, or at the first heartbeat
  that finds it alive (30 seconds); only then is the outage over, the backoff
  and the refusal count reset, and the source's row `connected`. Until then a
  source that keeps being refused shows `reconnecting` and backs off.

  **Items are judged before they are stored** (M60_CUE_INTAKE_AT_SCALE.md
  §3.2). Each item of a frame goes through the words of the source's `llm`
  watchers (`Cues.ListenFor`): one no watcher's words matched is counted
  `unmatched`; the rate buckets (`Cues.Buckets.admit/3`) and the daily budget
  apply to the matched ones; the rest go to `Cues.LiveFilters` with the
  watchers whose words matched, where each is judged and only a pass is
  stored. While a decision model screens in place of the words
  (`Cues.Config.screen_provider/0`, read for each frame), every item goes to
  every `llm` watcher that has words, and its filter call screens it first
  (`Cues.Filter`). A
  stream routes nothing to a `none` watcher, and never goes through
  `Cues.Ingest.accept/3`. Repeats are refused at a pass, by identity.

  **Watchers.** At connect and on every flush of a live connection the worker
  reads its source's enabled watchers (`{:source_watchers, ref}`) and what a
  live call needs (`{:live_context, ...}`), compiles each watcher's words
  (again only when they changed) and hands its `llm` watchers to
  `Cues.LiveFilters`. A read that fails at connect is a disconnect; one that
  fails on a flush keeps the watchers it had.

  **The flush.** Every 10 seconds, and once at a clean stop, the worker writes
  its counts (`Cues.Counts`: received, unmatched, rate_limited, over_budget,
  invalid, stale) as absolute totals for the hour, and, on a live connection,
  the source's row: `status`, the last good time and the day's count of
  matched items. A counts write that fails is sent again by the next flush.

  **No cursor.** `cue_sources.last_good_at` is the local time the connection
  was last known good (a frame or a pong is the evidence), written by the
  flush and once more when the connection drops. Every connection starts at
  the live tip: what the service sends while it is disconnected is missed,
  and no gap is recorded for it, since its size is unknown.

  **Limits.** A frame over 1 MiB closes the connection with a `read_limit`
  gap, whether the reader refuses it or the transport ends the connection
  before it is whole (`:frame_too_large`); the gap's range runs from what was
  known complete to the close. A frame of more than 100 messages keeps the
  first 100 and records the rest as a `page_limit` gap. A connection silent
  past 90 seconds (no frame, no answer to the 30-second ping) is closed and
  dialled again.

  **Failures.** Reconnects back off from one second doubling to a minute, and
  never stop. A write of the source's row that fails, a Repo that does not
  answer in time included, closes the connection, which is dialled again; no
  Repo timeout stops the worker. The owner is told of an outage once (`:down`)
  when it is longer than 15 minutes. A refused credential (HTTP 401 or 403 at the upgrade) stops
  the worker with status `auth_failed` and a notice (`:auth_failed`); a route
  through the proxy, which a WebSocket cannot take, or a host that resolves to
  an address `Net.Guard` refuses, stops it with status `unavailable` and a
  notice (`:unreachable`). An error message from the service (a type in
  `error_types`) closes the connection; one from a connection that delivered
  no item is a refusal, a healthy connection resets the count, and the eighth
  refusal in a row stops the worker with status `stopped` and a notice
  (`:refused`). The service's words go to the log and the trace (behind the
  content gate) only. Past the daily budget (matched items, counted here,
  read back from the row at start) the stream is closed until the next UTC
  day, the row reads `over_budget`, and the owner is told once that day
  (`:budget_reached`).

  Status in `cue_sources`: `connected`, `reconnecting`, `auth_failed`,
  `unavailable`, `stopped`, `over_budget`. Source telemetry: `connect`,
  `reconnect`, `disconnect` (`reason: :service_error` for a service's error),
  `auth_failure`, `budget`, `gap`, `stopped` (`reason: :refused` after the
  eighth refusal). The items it does not store are counted lifecycle phases
  (`Cues.Counts`), one event per phase per flush.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.Counts
  alias FermixCore.Cues.Item
  alias FermixCore.Cues.JsonStream
  alias FermixCore.Cues.ListenFor
  alias FermixCore.Cues.LiveFilters
  alias FermixCore.Cues.Source.Stream.Socket
  alias FermixCore.Cues.Source.Worker
  alias FermixCore.Memory.Repo.CuesFilterSql
  alias FermixCore.Memory.Repo.CuesWatchersSql
  alias FermixCore.Setup.SecretWriter

  @flush_ms 10_000
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
  # The clean stop's count flush is bounded well under the supervisor's
  # shutdown (5 s by default), which would kill the worker mid-call.
  @stop_flush_ms 2_000

  @doc """
  Starts the worker for `opts[:source]` (a `Cues.Config.sources/0` map of kind
  `:stream`). Other options, each with a production default: `:repo`,
  `:repo_timeout_ms`, `:clock` (zero-arity, a `DateTime`), `:monotonic_ms`,
  `:schedule` (`(message, ms) -> term`), `:transport` (a module with this
  module's callbacks), `:transport_opts` (added to the transport's options),
  `:admit` (`(ref, n, now_ms) -> admitted`, default `Cues.Buckets.admit/3`),
  `:live` (the `Cues.LiveFilters` server, default its name), `:words?`
  (zero-arity, whether items are routed by words; default: unless
  `Cues.Config.screen_provider/0` names a provider), `:notify`
  (default `Cues.Notices.source/4`), `:manager` (a pid linked from `init`;
  `Cues.SourceManager` passes itself). A transport implements
  `Cues.Source.Stream.Transport`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    %{ref: ref, kind: :stream} = Keyword.fetch!(opts, :source)
    true = is_binary(ref)
    GenServer.start_link(__MODULE__, opts)
  end

  # Exits are trapped so a stop from the supervisor runs `terminate/2`, which
  # writes the counts; the manager's link still ends the worker with it.
  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    base = Worker.base_state(opts)

    state =
      Map.merge(base, %{
        transport: Keyword.get(opts, :transport, Socket),
        transport_opts: Keyword.get(opts, :transport_opts, []),
        live: Keyword.get(opts, :live, LiveFilters),
        words?: Keyword.get(opts, :words?, fn -> is_nil(CuesConfig.screen_provider()) end),
        socket: nil,
        socket_ref: nil,
        closing: nil,
        phase: :idle,
        ever_connected?: false,
        failures: 0,
        alive_at: nil,
        watchers: [],
        counts: Counts.new("source"),
        spent: {nil, 0},
        spent_written: nil,
        down_since: nil,
        down_notified?: false,
        refusals: 0,
        delivered?: false,
        healthy?: false
      })

    {:ok, state |> Worker.schedule(:connect, 0) |> Worker.schedule(:flush, @flush_ms)}
  end

  @impl true
  def handle_info({:timer, kind, token}, state) do
    case Worker.take_timer(state, kind, token) do
      {:due, state} -> on_timer(kind, state)
      :stale -> {:noreply, state}
    end
  end

  # After the source's row failed to be written, the connection is closing and
  # nothing more from it is taken (see `put_state/3`). Every frame is
  # acknowledged once handled, so the transport reads on.
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

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  # A clean stop writes what was counted since the last flush, bounded by
  # `@stop_flush_ms`.
  @impl true
  def terminate(_reason, state) do
    write_counts(%{state | repo_timeout_ms: @stop_flush_ms}, state.clock.())
    :ok
  end

  # --- timers ----------------------------------------------------------------------

  defp on_timer(:connect, state), do: connect(state, state.clock.())
  defp on_timer(:flush, state), do: {:noreply, flush(state, state.clock.())}
  # A closing connection has no heartbeat: its close is bounded by the transport.
  defp on_timer(:heartbeat, %{phase: :connected, closing: nil} = state),
    do: heartbeat(state, state.clock.())

  defp on_timer(:heartbeat, state), do: {:noreply, state}
  defp on_timer(:down, state), do: {:noreply, down_notice(state)}

  # --- connecting --------------------------------------------------------------------

  defp connect(state, now) do
    with {:ok, state} <- load(state, now),
         {:ok, state} <- read_watchers(state, now) do
      if Worker.paused?(state, now),
        do: {:noreply, Worker.schedule(state, :connect, Worker.ms_to_next_day(now))},
        else: dial(state, now)
    else
      {:error, reason} -> disconnected(state, {:load, reason}, now)
    end
  end

  defp dial(state, now) do
    case sign_in(state.source) do
      {:ok, plan} -> start_socket(state, plan, now)
      {:error, reason} -> disconnected(state, reason, now)
    end
  end

  # How to sign in: the source's sign-in headers and messages, built from the
  # secrets as they are stored now (one read per connection) and kept in no
  # state. A secret that cannot be read, or cannot be sent, is a disconnect
  # before dialling.
  defp sign_in(source) do
    with {:ok, secrets} <- read_secrets(source),
         {:ok, headers} <- JsonStream.headers(source, secrets),
         {:ok, messages} <- JsonStream.messages(source, secrets) do
      {:ok, %{headers: headers, messages: messages}}
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

  defp start_socket(state, plan, now) do
    opts =
      [
        handshake_timeout: @handshake_timeout_ms,
        headers: plan.headers,
        messages: plan.messages,
        max_frame_bytes: JsonStream.max_frame_bytes()
      ] ++ state.transport_opts

    # The transport took the monitor in this process before returning, so its
    # exit cannot come unwatched.
    case state.transport.start(state.source.url, self(), opts) do
      {:ok, socket, monitor} ->
        {:noreply, %{state | socket: socket, socket_ref: monitor, phase: :connecting}}

      {:error, :proxy_unsupported_transport} ->
        proxied(state, now)

      {:error, reason} ->
        disconnected(state, reason, now)
    end
  end

  # The upgrade is traced, but proves nothing yet (`healthy/2`): the outage,
  # the backoff and the refusal count stand until the connection does.
  defp on_socket(:connected, state) do
    now = state.clock.()
    phase = if state.ever_connected?, do: :reconnect, else: :connect
    Worker.trace(state, phase, %{status: "connected", attempt: state.failures})

    state = %{
      state
      | phase: :connected,
        ever_connected?: true,
        alive_at: now,
        delivered?: false,
        healthy?: false
    }

    {:noreply, Worker.schedule(state, :heartbeat, @heartbeat_ms)}
  end

  defp on_socket(:pong, state), do: {:noreply, %{state | alive_at: state.clock.()}}

  # The reader refuses a frame over its cap before the frame counts as
  # evidence the connection is alive.
  defp on_socket({:frame, frame}, state) do
    now = state.clock.()

    case JsonStream.read(frame, state.source) do
      {:ok, read} -> {:noreply, json_read(%{state | alive_at: now}, read, now)}
      {:error, :frame_too_large} -> {:noreply, too_large(state, now)}
    end
  end

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

  # --- frames --------------------------------------------------------------------------

  # A frame's messages, in order. More than 100 is a `page_limit` gap for the
  # rest; an item proves the connection healthy. Its items are routed at once.
  defp json_read(state, %{entries: entries, over_limit: over}, now) do
    if over > 0, do: Worker.gap(state, "page_limit", over, {now, now}, now)
    {state, items} = Enum.reduce(entries, {state, []}, &json_entry(&1, &2, now))
    route(state, Enum.reverse(items), now)
  end

  defp json_entry({:item, fields}, {state, items}, now) do
    state = %{healthy(state, now) | delivered?: true} |> counted("received", 1, now)

    case Item.new(fields, now) do
      {:ok, item} -> {state, [item | items]}
      {:error, :stale} -> {counted(state, "stale", 1, now), items}
      {:error, {:invalid, _sentence}} -> {counted(state, "invalid", 1, now), items}
    end
  end

  defp json_entry({:reject, _sentence}, {state, items}, now),
    do: {state |> counted("received", 1, now) |> counted("invalid", 1, now), items}

  defp json_entry({:service_error, words}, {state, items}, _now),
    do: {service_error(state, words), items}

  defp json_entry(:skip, {state, _items} = acc, _now) do
    Logger.debug("Cue stream #{state.source.ref}: skipped a message that is not an item")
    acc
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

  # --- routing (M60_CUE_INTAKE_AT_SCALE.md §3.2) --------------------------------------

  # Each item through the words of the source's `llm` watchers; the matched
  # ones through the rate buckets and the daily budget, then to
  # `Cues.LiveFilters` with the watchers whose words matched. Nothing about an
  # item is written here.
  defp route(state, [], _now), do: state

  defp route(state, items, now) do
    words? = state.words?.()

    matched =
      for item <- items, ids = listeners(state.watchers, item, words?), ids != [], do: {item, ids}

    state = counted(state, "unmatched", length(items) - length(matched), now)
    {admitted, state} = admit(state, matched, now)
    {offers, state} = within_budget(state, admitted, now)
    if offers != [], do: LiveFilters.offer(state.live, state.source.ref, offers)
    state
  end

  # The item's text is prepared once for every watcher of the source; with a
  # screen in place of the words, every watcher that has words listens (one
  # with none waits for its update either way).
  defp listeners([], _item, _words?), do: []
  defp listeners(watchers, _item, false), do: for(%{id: id, words: [_ | _]} <- watchers, do: id)

  defp listeners(watchers, item, true) do
    prepared = ListenFor.prepare(item)
    for %{id: id, matcher: matcher} <- watchers, ListenFor.match?(matcher, prepared), do: id
  end

  defp admit(state, [], _now), do: {[], state}

  defp admit(state, matched, now) do
    wanted = length(matched)
    granted = state.admit.(state.source.ref, wanted, state.monotonic_ms.())
    true = is_integer(granted) and granted in 0..wanted
    {taken, refused} = Enum.split(matched, granted)
    {taken, counted(state, "rate_limited", length(refused), now)}
  end

  # The daily budget (0 = none) counts the matched items the source took today
  # (UTC); past it the rest are `over_budget` and the stream pauses.
  defp within_budget(%{source: %{daily_budget: 0}} = state, offers, now),
    do: {offers, spend(state, length(offers), now)}

  defp within_budget(state, offers, now) do
    room = max(state.source.daily_budget - spent_today(state, now), 0)
    {taken, over} = Enum.split(offers, room)
    state = spend(state, length(taken), now)

    if over == [],
      do: {taken, state},
      else: {taken, state |> counted("over_budget", length(over), now) |> budget_reached(now)}
  end

  defp spent_today(%{spent: {day, n}}, now), do: if(day == utc_day(now), do: n, else: 0)

  defp spend(state, n, now), do: %{state | spent: {utc_day(now), spent_today(state, now) + n}}

  defp utc_day(now), do: now |> Worker.utc_date() |> Date.to_iso8601()

  defp counted(state, name, n, now),
    do: %{state | counts: Counts.add(state.counts, state.source.ref, name, n, now)}

  # --- the flush -----------------------------------------------------------------------

  # Every 10 s: the counts, and on a live connection the source's row and the
  # watchers.
  defp flush(state, now) do
    state = write_counts(state, now)

    state =
      if live?(state),
        do: state |> write_state(live_status(state), now) |> refresh_watchers(now),
        else: state

    Worker.schedule(state, :flush, @flush_ms)
  end

  defp live?(state), do: state.phase == :connected and state.closing == nil

  # Absolute totals for the hour: one that failed is sent again by the next.
  defp write_counts(state, now) do
    state = %{state | counts: Counts.report(state.counts)}

    case Counts.rows(state.counts) do
      [] -> state
      rows -> wrote_counts(state, rows, Worker.repo_call(state, {:counts_put, rows, now}), now)
    end
  end

  defp wrote_counts(state, rows, {:ok, _written}, now),
    do: %{state | counts: Counts.written(state.counts, rows, now)}

  defp wrote_counts(state, _rows, {:error, _traced}, _now), do: state

  # The source's row: the last good time it covers, the status (nil leaves it)
  # and the day's count of matched items, written when either moved. A write
  # that fails closes the connection, the failed-write path; until that close
  # lands nothing more is written, so `last_good_at` never moves past it.
  defp write_state(%{closing: :ingest_failed} = state, _status, _now), do: state

  defp write_state(state, status, now) do
    if advanced?(state) or state.spent != state.spent_written,
      do: put_state(state, status, now),
      else: state
  end

  defp put_state(state, status, now) do
    covered = state.alive_at
    attrs = Map.merge(%{last_good_at: covered, status: status}, spent_attrs(state))

    case Worker.repo_call(state, {:source_touch, state.source.ref, attrs, now}) do
      {:ok, _row} ->
        last_good_at = later(state.last_good_at, covered)
        %{state | last_good_at: last_good_at, spent_written: state.spent}

      {:error, _traced} ->
        close_socket(state, :ingest_failed)
    end
  end

  defp spent_attrs(%{spent: {nil, _n}}), do: %{}
  defp spent_attrs(%{spent: {day, n}}), do: %{items_today: n, items_day: day}

  # Whether the last frame or pong, how far the received stream is known
  # complete, is past the last good time written.
  defp advanced?(%{alive_at: nil}), do: false

  defp advanced?(%{alive_at: alive, last_good_at: good}),
    do: good == nil or DateTime.compare(alive, good) == :gt

  defp later(nil, at), do: at
  defp later(at, nil), do: at
  defp later(at, other), do: if(DateTime.compare(at, other) == :lt, do: other, else: at)

  # --- watchers --------------------------------------------------------------------------

  # The source's enabled watchers, read at connect and on every flush: a
  # stream routes nothing to a `none` watcher, and each `llm` watcher's words
  # compile again only when they changed. Its `llm` watchers, with what a
  # live call needs, go to `Cues.LiveFilters`.
  defp read_watchers(state, now) do
    ref = state.source.ref

    with {:ok, rows} <- Worker.repo_call(state, CuesWatchersSql, {:source_watchers, ref}),
         llm = Enum.filter(rows, &(&1.filter == "llm")),
         {:ok, context} <-
           Worker.repo_call(state, CuesFilterSql, {:live_context, Enum.map(llm, & &1.id), now}) do
      LiveFilters.watchers(state.live, ref, Enum.map(llm, &spec(&1, context)))
      {:ok, %{state | watchers: Enum.map(llm, &compiled(&1, state.watchers))}}
    end
  end

  # On a flush a read that fails keeps the watchers the worker had.
  defp refresh_watchers(state, now) do
    case read_watchers(state, now) do
      {:ok, state} -> state
      {:error, _traced} -> state
    end
  end

  defp spec(watcher, context) do
    watcher
    |> Map.take([
      :id,
      :name,
      :purpose,
      :listen_for,
      :filter_budget,
      :filter_failures,
      :filter_retry_at
    ])
    |> Map.merge(Map.fetch!(context, watcher.id))
  end

  defp compiled(%{id: id, listen_for: words}, previous) do
    case Enum.find(previous, &(&1.id == id and &1.words == words)) do
      nil -> %{id: id, words: words, matcher: ListenFor.compile(words)}
      same -> same
    end
  end

  # --- liveness and limits -------------------------------------------------------------

  defp heartbeat(state, now) do
    if DateTime.diff(now, state.alive_at, :millisecond) > @stall_ms do
      Logger.warning("Cue stream #{state.source.ref}: no frame or pong for 90 s; reconnecting")
      {:noreply, close_socket(state, :stalled)}
    else
      state.transport.ping(state.socket)
      {:noreply, state |> healthy(now) |> Worker.schedule(:heartbeat, @heartbeat_ms)}
    end
  end

  # The gap's range runs from what was known complete (the last frame or pong)
  # to now. The same holds when the transport ended the connection at such a
  # frame (`read_limit_down/3`).
  defp too_large(state, now) do
    Worker.gap(state, "read_limit", 1, {state.alive_at || now, now}, now)
    close_socket(state, :read_limit)
  end

  defp close_socket(%{socket: nil} = state, _reason), do: state
  defp close_socket(%{closing: :ingest_failed} = state, _reason), do: state

  defp close_socket(state, reason) do
    state.transport.close(state.socket)
    %{state | closing: reason}
  end

  # --- disconnects -----------------------------------------------------------------------

  # The source's row is written first, with what the connection covered. A
  # budget that ran out has paused the stream already: that drop is no
  # outage. A failed write (now or before) is what the drop reports.
  defp on_down(reason, state) do
    now = state.clock.()
    closing = state.closing
    from = state.alive_at || now
    state = write_state(state, "reconnecting", now)
    ingest_failed? = state.closing == :ingest_failed
    state = forget_socket(state)

    ended(reason, closing, %{from: from, ingest_failed?: ingest_failed?}, state, now)
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
  # whole: a `read_limit` gap, unless the source's row failed to be written,
  # which the drop reports instead.
  defp read_limit_down(state, %{ingest_failed?: true}, now),
    do: disconnected(state, :ingest_failed, now)

  defp read_limit_down(state, %{from: from}, now) do
    Worker.gap(state, "read_limit", 1, {from, now}, now)
    disconnected(state, :read_limit, now)
  end

  # The heartbeat goes with the dropped connection; the flush does not.
  defp forget_socket(state) do
    %{state | socket: nil, socket_ref: nil, closing: nil, healthy?: false}
    |> Worker.drop_timer(:heartbeat)
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
    Worker.schedule(state, :down, @down_notice_ms)
  end

  defp down_notice(%{healthy?: true} = state), do: state
  defp down_notice(%{down_notified?: true} = state), do: state
  defp down_notice(%{down_since: nil} = state), do: state

  defp down_notice(state) do
    data = %{since: DateTime.to_iso8601(state.down_since)}
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
       when reason in [:read_limit, :stalled, :ingest_failed, :url_without_host],
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

  # The row says so at once, with the day's count, so a restart today stays
  # paused (`Worker.load/2`).
  defp budget_reached(state, now) do
    state = Worker.budget_reached(state, now)
    Worker.touch(state, Map.put(spent_attrs(state), :status, "over_budget"), now)

    # Forget the socket before closing it: its exit is no outage.
    if state.socket_ref, do: Process.demonitor(state.socket_ref, [:flush])
    if state.socket, do: state.transport.close(state.socket)

    %{state | socket: nil, socket_ref: nil, phase: :paused}
    |> Worker.drop_timer(:heartbeat)
    |> Worker.schedule(:connect, Worker.ms_to_next_day(now))
  end

  # --- the source's row ------------------------------------------------------------------

  # The day's count of matched items comes back from the row once, at start.
  defp load(state, now) do
    case Worker.load(state, now) do
      {:ok, state, nil} -> {:ok, state}
      {:ok, state, row} -> {:ok, %{state | spent: spent_of(row), spent_written: spent_of(row)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp spent_of(%{items_day: day, items_today: n}) when is_binary(day), do: {day, n}
  defp spent_of(_row), do: {nil, 0}
end
