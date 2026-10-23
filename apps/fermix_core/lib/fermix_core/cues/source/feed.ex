defmodule FermixCore.Cues.Source.Feed do
  @moduledoc """
  One feed source's poll loop (M60 §6.4, §6.8, §6.9): an RSS, Atom or JSON
  Feed, or a JSON API when the source names an `items_path`.

  Every `interval` seconds (at least 60) it makes one conditional request
  (`If-None-Match`/`If-Modified-Since` from the `ETag`/`Last-Modified` kept as
  JSON in `cue_sources.cursor`) through `Net.HttpClient`:

    * `304`: no items; the source's `last_good_at` moves.
    * `200`: the body is read with a cap of 4 MiB after decompression (gzip is
      asked for and inflated in bounded steps); past the cap the connection is
      closed and a `read_limit` gap recorded. The body goes through
      `Cues.FeedParser`, whose items become `Cues.Item`s (an item it refuses is
      counted as a reject) and go to `Cues.Ingest.accept/3` in one transaction
      with the new cursor, `last_good_at` and `status: "polling"`. A page with
      more than 100 items records the rest as a `page_limit` gap with its range.
    * Redirects: at most 3, `https` only, each hop checked by `Net.Guard` (no
      private, loopback or link-local address) before it is requested.

  The first successful read after the source is added (no `last_good_at` yet)
  stores undated items as receipts with no delivery (design §6.8).

  **Budget.** When `Cues.Ingest` reports `:over_budget`, polling stops until
  the next UTC day and the owner is told once that day
  (`Cues.Notices.source/4`, `:budget_reached`). A worker started on a day whose
  budget is spent waits too.

  **Failures** (a transport error, an HTTP status other than 200 or 304, a
  refused hop, an unreadable body, a failed transaction) are traced and retried
  inside the worker, after one minute doubling to an hour. The eighth failure
  in a row stops the worker normally with a source notice (`:unreachable`), so
  a failing source never spends the supervisor's restart budget (§5.3). A
  configured URL that is not `https`, or JSON API paths that do not parse, stop
  it at once with status `unavailable`.

  Note: `Net.Guard` resolves and checks each hop's host before the request,
  and the request resolves it again; the shared pool `Net.HttpClient` uses
  cannot be pinned to the checked address.

  Every function that reads time takes it from the injected clock; timers go
  through the injected `:schedule` and carry a token, so a stale one is
  ignored.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.Cues.FeedParser
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Item
  alias FermixCore.Cues.Source.Worker
  alias FermixCore.Net.Guard
  alias FermixCore.Net.HttpClient

  @min_interval_s 60
  @max_body_bytes 4 * 1024 * 1024
  @max_redirects 3
  @redirect_statuses [301, 302, 303, 307, 308]
  @receive_timeout_ms 30_000
  @first_retry_ms 60_000
  @max_retry_ms 3_600_000
  @max_failures 8
  @first_poll_spread_ms 30_000
  @max_inflate_steps 4_096
  @max_validator_bytes 1_024
  @path_keys [:items_path, :id_path, :revision_path, :type_path, :subject_path, :time_path]
  @label "Cue feed"
  @accept "application/feed+json, application/atom+xml, application/rss+xml, " <>
            "application/json;q=0.9, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5"

  @doc """
  Starts the worker for `opts[:source]` (a `Cues.Config.sources/0` map of kind
  `:feed`). Other options, each with a production default: `:repo`, `:clock`
  (zero-arity, a `DateTime`), `:monotonic_ms`, `:schedule` (`(message, ms) ->
  term`), `:req_options` (merged into the request; a test's `plug:`),
  `:resolver` (for `Net.Guard`), `:egress`, `:admit` (`(ref, n, now_ms) ->
  admitted`, default `Cues.Buckets.admit/3`), `:notify` (default
  `Cues.Notices.source/4`), `:manager` (a pid linked from `init`;
  `Cues.SourceManager` passes itself).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    %{ref: ref, kind: :feed, url: url} = Keyword.fetch!(opts, :source)
    true = is_binary(ref) and is_binary(url)
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state =
      opts
      |> Worker.base_state()
      |> Map.merge(%{
        req_options: Keyword.get(opts, :req_options, []),
        resolver: Keyword.get(opts, :resolver),
        egress: Keyword.get(opts, :egress),
        cursor: %{},
        polled?: false,
        failures: 0
      })

    # Spread so that sources started together do not all poll at once.
    spread_ms = :erlang.phash2(state.source.ref, @first_poll_spread_ms)
    {:ok, Worker.schedule(state, :poll, spread_ms)}
  end

  @impl true
  def handle_info({:timer, kind, token}, state) do
    case Worker.take_timer(state, kind, token) do
      {:due, state} -> on_timer(kind, state)
      :stale -> {:noreply, state}
    end
  end

  defp on_timer(:poll, state) do
    now = state.clock.()

    with :ok <- check_source(state.source),
         {:ok, state} <- load(state, now) do
      poll(state, now)
    else
      {:error, {:misconfigured, reason}} -> misconfigured(state, reason, now)
      {:error, reason} -> failed(state, {:load, reason}, now)
    end
  end

  defp poll(state, now) do
    if Worker.paused?(state, now),
      do: {:noreply, Worker.schedule(state, :poll, Worker.ms_to_next_day(now))},
      else: fetch_and_accept(state, now)
  end

  # --- the poll ------------------------------------------------------------------

  defp fetch_and_accept(state, now) do
    case fetch(state, state.source.url, 0) do
      {:ok, %Req.Response{status: 304}, _url} -> accepted(state, {[], nil, :complete}, now)
      {:ok, response, url} -> read(state, response, url, now)
      {:error, reason} -> failed(state, reason, now)
    end
  end

  defp read(state, response, url, now) do
    with {:ok, body} <- body(response),
         {:ok, fields, truncation} <- parse(state.source, body, content_type(response), url) do
      first? = state.last_good_at == nil
      entries = Enum.map(fields, &entry(&1, first?, now))
      accepted(state, {entries, cursor_json(response), truncation}, now)
    else
      {:error, :read_limit} -> read_limit(state, now)
      {:error, reason} -> failed(state, reason, now)
    end
  end

  # One transaction for the items, the new cursor and the last good time; the
  # page_limit gap is recorded only once the page it belongs to is in.
  defp accepted(state, {entries, cursor, truncation}, now) do
    source_state = %{cursor: cursor, last_good_at: now, status: "polling"}

    opts = [
      now: now,
      repo: state.repo,
      admit: Worker.admit_fun(state),
      source_state: source_state
    ]

    case Ingest.accept(Worker.ingest_source(state), entries, opts) do
      {:ok, results} ->
        state = state |> polled(cursor, now) |> page_limit(truncation, now)
        {:noreply, state |> over_budget(results, now) |> next_poll(now)}

      {:error, reason} ->
        failed(state, {:ingest, reason}, now)
    end
  end

  defp polled(state, cursor, now) do
    phase = if state.polled?, do: :reconnect, else: :connect

    if state.failures > 0 or not state.polled?,
      do: Worker.trace(state, phase, %{status: "polling", attempt: state.failures})

    %{
      state
      | polled?: true,
        failures: 0,
        last_good_at: now,
        cursor: if(cursor, do: decode_cursor(cursor), else: state.cursor)
    }
  end

  defp next_poll(state, now) do
    if Worker.paused?(state, now),
      do: Worker.schedule(state, :poll, Worker.ms_to_next_day(now)),
      else: Worker.schedule(state, :poll, interval_ms(state.source))
  end

  defp entry(%{occurred_at: nil} = fields, true, now),
    do: fields |> Map.put(:receipt_only?, true) |> Item.new(now) |> Worker.unwrap()

  defp entry(fields, _first?, now), do: fields |> Item.new(now) |> Worker.unwrap()

  # --- fetch -------------------------------------------------------------------------

  defp fetch(_state, _url, hop) when hop > @max_redirects, do: {:error, :too_many_redirects}

  defp fetch(state, url, hop) do
    with :ok <- https(url),
         :ok <- Guard.validate(url, resolver: state.resolver),
         {:ok, response} <- request(state, url) do
      follow(state, url, response, hop)
    end
  end

  defp follow(state, url, %Req.Response{status: status} = response, hop)
       when status in @redirect_statuses do
    case Req.Response.get_header(response, "location") do
      [location | _rest] -> fetch(state, url |> URI.merge(location) |> URI.to_string(), hop + 1)
      [] -> {:error, :redirect_without_location}
    end
  end

  defp follow(_state, url, %Req.Response{status: status} = response, _hop)
       when status in [200, 304],
       do: {:ok, response, url}

  defp follow(_state, _url, %Req.Response{status: status}, _hop),
    do: {:error, {:http_status, status}}

  defp https(url) do
    if URI.parse(url).scheme == "https", do: :ok, else: {:error, :not_https}
  end

  defp request(state, url) do
    headers =
      [{"user-agent", user_agent()}, {"accept", @accept}, {"accept-encoding", "gzip"}] ++
        conditional_headers(state.cursor)

    [
      method: :get,
      url: url,
      headers: headers,
      redirect: false,
      retry: false,
      compressed: false,
      decode_body: false,
      receive_timeout: @receive_timeout_ms,
      into: &capped/2
    ]
    |> Keyword.merge(state.req_options)
    |> Req.new()
    |> send_request(state.egress)
  end

  defp send_request(request, nil), do: HttpClient.request(request, @label)
  defp send_request(request, egress), do: HttpClient.request(request, @label, egress)

  # Collects the raw body and halts (closing the connection) past the cap.
  defp capped({:data, data}, {request, response}) do
    body = if is_binary(response.body), do: response.body, else: ""

    if byte_size(body) + byte_size(data) > @max_body_bytes,
      do: {:halt, {request, Req.Response.put_private(response, :cue_read_limit, true)}},
      else: {:cont, {request, %{response | body: body <> data}}}
  end

  defp conditional_headers(cursor) do
    Enum.flat_map([{"etag", "if-none-match"}, {"last_modified", "if-modified-since"}], fn
      {key, header} ->
        case Map.get(cursor, key) do
          value when is_binary(value) -> [{header, value}]
          _absent -> []
        end
    end)
  end

  defp cursor_json(response) do
    %{
      "etag" => validator(response, "etag"),
      "last_modified" => validator(response, "last-modified")
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Jason.encode!()
  end

  defp validator(response, header) do
    case Req.Response.get_header(response, header) do
      [value | _rest] when byte_size(value) <= @max_validator_bytes -> value
      _absent_or_too_long -> nil
    end
  end

  # --- body ------------------------------------------------------------------------

  defp body(%Req.Response{private: %{cue_read_limit: true}}), do: {:error, :read_limit}

  defp body(response) do
    raw = if is_binary(response.body), do: response.body, else: ""

    response
    |> Req.Response.get_header("content-encoding")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> decode_body(raw)
  end

  defp decode_body([], raw), do: {:ok, raw}
  defp decode_body(["identity"], raw), do: {:ok, raw}
  defp decode_body([gzip], raw) when gzip in ["gzip", "x-gzip"], do: gunzip(raw)
  defp decode_body(codings, _raw), do: {:error, {:unsupported_encoding, Enum.join(codings, ",")}}

  # Inflates in bounded steps and stops past the cap, so a small body that
  # inflates to gigabytes is never held in memory.
  defp gunzip(data) do
    zstream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(zstream, 31)
      inflate(zstream, :zlib.safeInflate(zstream, data), [], 0, 1)
    rescue
      error in ErlangError ->
        if error.original == :data_error,
          do: {:error, {:invalid_gzip, :data_error}},
          else: reraise(error, __STACKTRACE__)
    after
      :zlib.close(zstream)
    end
  end

  defp inflate(zstream, {status, output}, acc, size, steps) do
    size = size + IO.iodata_length(output)
    acc = [output | acc]

    cond do
      size > @max_body_bytes -> {:error, :read_limit}
      status == :finished -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      steps >= @max_inflate_steps -> {:error, {:invalid_gzip, :too_many_steps}}
      true -> inflate(zstream, :zlib.safeInflate(zstream, []), acc, size, steps + 1)
    end
  end

  defp content_type(response),
    do: response |> Req.Response.get_header("content-type") |> List.first()

  defp parse(%{items_path: path} = source, body, _content_type, _url) when is_binary(path),
    do: FeedParser.parse_json_api(body, json_paths(source))

  defp parse(_source, body, content_type, url),
    do: FeedParser.parse(body, content_type, base_url: url)

  defp json_paths(source) do
    for key <- @path_keys, value = Map.get(source, key), into: %{}, do: {key, value}
  end

  # --- gaps --------------------------------------------------------------------------

  defp read_limit(state, now) do
    Worker.gap(state, "read_limit", 1, nil, now)
    {:noreply, Worker.schedule(state, :poll, interval_ms(state.source))}
  end

  defp page_limit(state, :complete, _now), do: state

  defp page_limit(state, {:truncated, %{count: count, range_from: from, range_to: to}}, now) do
    Worker.gap(state, "page_limit", count, {from, to}, now)
    state
  end

  # --- budget --------------------------------------------------------------------------

  defp over_budget(state, results, now) do
    if :over_budget in results, do: Worker.budget_reached(state, now), else: state
  end

  # --- failures ----------------------------------------------------------------------

  defp failed(state, reason, now) do
    failures = state.failures + 1
    label = failure_label(reason)
    Worker.trace(state, :disconnect, %{reason: label, attempt: failures, result: {:error, label}})
    Logger.warning("Cue feed #{state.source.ref} poll #{failures} failed: #{inspect(reason)}")

    if failures >= @max_failures,
      do: give_up(%{state | failures: failures}, label, now),
      else: {:noreply, Worker.schedule(%{state | failures: failures}, :poll, retry_ms(failures))}
  end

  defp give_up(state, label, now) do
    Worker.touch(state, %{status: "stopped"}, now)

    Worker.trace(state, :stopped, %{
      status: "stopped",
      reason: label,
      attempt: state.failures,
      result: {:error, label}
    })

    Logger.error("Cue feed #{state.source.ref} failed #{state.failures} polls in a row; stopped")

    Worker.notify(
      state,
      :unreachable,
      %{failures: state.failures, reason: Atom.to_string(label)},
      now
    )

    {:stop, :normal, state}
  end

  defp misconfigured(state, reason, now) do
    Worker.touch(state, %{status: "unavailable"}, now)

    Worker.trace(state, :stopped, %{
      status: "unavailable",
      reason: reason,
      result: {:error, reason}
    })

    Logger.error("Cue feed #{state.source.ref} cannot be polled (#{reason}); fix its settings")
    {:stop, :normal, state}
  end

  defp retry_ms(failures), do: Worker.backoff_ms(failures, @first_retry_ms, @max_retry_ms)

  # A short label for the trace; the whole reason goes to the log.
  defp failure_label({:blocked_host, _detail}), do: :blocked
  defp failure_label({:resolved_to_private_address, _ip}), do: :blocked
  defp failure_label({:dns_resolution_failed, _detail}), do: :dns_failed
  defp failure_label({:http_status, _status}), do: :http_status
  defp failure_label({:load, _reason}), do: :repo
  defp failure_label({:ingest, _reason}), do: :repo
  defp failure_label(%Req.TransportError{reason: reason}) when is_atom(reason), do: reason
  defp failure_label(%{__exception__: true}), do: :transport
  defp failure_label(reason) when is_atom(reason), do: reason

  defp failure_label(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp failure_label(_reason), do: :failed

  # --- the source's row ------------------------------------------------------------

  defp check_source(source) do
    with :ok <- https_url(source.url) do
      json_paths_valid(source)
    end
  end

  defp https_url(url) do
    case https(url) do
      :ok -> :ok
      {:error, :not_https} -> {:error, {:misconfigured, :not_https}}
    end
  end

  defp json_paths_valid(%{items_path: path} = source) when is_binary(path) do
    case FeedParser.validate_paths(json_paths(source)) do
      :ok -> :ok
      {:error, {:invalid_path, _key}} -> {:error, {:misconfigured, :invalid_paths}}
    end
  end

  defp json_paths_valid(_source), do: :ok

  defp load(state, now) do
    case Worker.load(state, now) do
      {:ok, state, nil} -> {:ok, state}
      {:ok, state, row} -> {:ok, %{state | cursor: decode_cursor(row.cursor)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Only this worker writes a feed's cursor, always a JSON object. Anything
  # else (a stream's time, left from when this ref was a stream) is no feed
  # cursor, so the next request is unconditional.
  defp decode_cursor(nil), do: %{}

  defp decode_cursor(text) do
    case Jason.decode(text) do
      {:ok, %{} = cursor} -> cursor
      _not_a_feed_cursor -> %{}
    end
  end

  # --- small helpers ---------------------------------------------------------------

  defp interval_ms(source), do: max(source.interval, @min_interval_s) * 1_000

  defp user_agent, do: "fermix/#{Application.spec(:fermix_core, :vsn) || "0.0.0"} (cues)"
end
