defmodule Mix.Tasks.Fermix.Cues.Load do
  @shortdoc "Pushes cues at a fixed rate into the running development daemon's door and reports what it measured"

  @moduledoc """
  A load check for the cue door (M60 §7.5): drives local-push sources at a
  fixed rate into the development daemon that serves the current
  `FERMIX_HOME`, then reports what it could measure.

      mix fermix.cues.load [--sources a,b,c] [--rate 10] [--seconds 30]

  `--sources` names enabled `local_push` sources (default: every enabled one),
  at most five, because the daemon admits 50 items a second in all; `--rate`
  is items a second per source, 1 to 10 (a source's bucket refills at 10 a
  second); `--seconds` is 1 to 600. Each source sends one CloudEvent per
  request, one request at a time (the door holds one authenticated request
  per source), at its scheduled times; a slow answer delays that source's
  next send, and the report says by how much. Sending stops 30 s after the
  planned end, and what was not sent by then is reported as not sent.

  It reports, per source and in all: items sent, accepted and refused (by
  the door's own per-event status or the HTTP status), the time from send to
  answer at the door (p50, p90, p99, max), and from the daemon's own trace
  files for the same window: the `accept_ms` of every accepted item it traced
  and the Repo calls that ran past their budget (`Timeouts.repo_call()`), from
  any caller. It cannot measure the latency of job and reminder claims and
  settles or of message persistence: no telemetry carries those, and this
  task never opens `memory.db` from a second VM; only a Repo call that runs
  past its budget shows. It exits non-zero when any item was not accepted.

  Every accepted item is routed to the watchers that listen to its source, so
  point it at sources no watcher listens to unless you mean to pay for their
  filter calls and task runs. It reads the current `FERMIX_HOME`'s config and
  the sources' tokens without the daemon tree, and changes nothing but the
  cues it posts.
  """

  use Mix.Task

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Net.Egress
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Timeouts

  @usage "usage: mix fermix.cues.load [--sources a,b,c] [--rate 10] [--seconds 30]"
  @max_sources 5
  @default_rate 10
  @max_rate 10
  @default_seconds 30
  @max_seconds 600
  @overrun_ms 30_000
  @request_timeout_ms 10_000
  @probe_timeout_ms 1_000
  @trace_grace_ms 2_000
  @max_trace_lines 2_000_000
  @content_type "application/cloudevents+json"
  @event_source "fermix.cues.load"
  @event_type "fermix.cues.load"

  @impl Mix.Task
  def run(args) do
    # Compiled code only: `app.config` would run `runtime.exs`, which resolves
    # every secret the home holds; this needs only the sources' tokens.
    Mix.Task.run("compile")
    {:ok, _apps} = Application.ensure_all_started(:req)
    execute(args)
  end

  @doc false
  @spec execute([String.t()], keyword()) :: :ok
  def execute(args, opts \\ []) when is_list(args) and is_list(opts) do
    plan = plan!(args, opts)
    probe!(plan, opts)
    Mix.shell().info(intro(plan))
    drive = drive(plan, opts)
    sleep(opts).(@trace_grace_ms)
    traced = traced(plan, drive.window, opts)
    Mix.shell().info(report(plan, drive, traced))
    refused = drive.totals.sent - drive.totals.accepted + drive.totals.unsent

    if refused > 0 do
      Mix.raise("#{refused} of #{drive.totals.planned} items were not accepted; see above.")
    end

    :ok
  end

  # --- the plan ------------------------------------------------------------------

  @doc false
  @spec plan!([String.t()], keyword()) :: map()
  def plan!(args, opts \\ []) when is_list(args) and is_list(opts) do
    {flags, rest, invalid} =
      OptionParser.parse(args, strict: [sources: :string, rate: :integer, seconds: :integer])

    if rest != [] or invalid != [], do: Mix.raise(@usage)

    rate = bounded!(Keyword.get(flags, :rate, @default_rate), 1..@max_rate, "--rate")

    seconds =
      bounded!(Keyword.get(flags, :seconds, @default_seconds), 1..@max_seconds, "--seconds")

    {cues, profile} = config!(opts)
    sources = sources!(Keyword.get(flags, :sources), cues)
    token = Keyword.get(opts, :token, &read_token(&1, profile))

    %{
      port: CuesConfig.door_port(cues),
      rate: rate,
      seconds: seconds,
      run_id: Keyword.get_lazy(opts, :run_id, &run_id/0),
      sources: Enum.map(sources, &Map.put(&1, :token, token!(token, &1)))
    }
  end

  defp bounded!(value, first..last//1 = range, flag) do
    if value in range,
      do: value,
      else: Mix.raise("#{flag} must be from #{first} to #{last}. #{@usage}")
  end

  defp config!(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, {cues, profile}} -> {cues, profile}
      :error -> read_config!()
    end
  end

  defp read_config! do
    case ConfigStore.load_runtime_config(resolve_secrets: false, supervised: false) do
      {:ok, snapshot} ->
        {Keyword.get(snapshot.fermix_core, :cues, []),
         Keyword.get(snapshot.fermix_core, :profile)}

      {:error, reason} ->
        Mix.raise("config.toml could not be read: #{ConfigStore.load_error_sentence(reason)}")
    end
  end

  defp sources!(named, cues) do
    pushable = Enum.filter(CuesConfig.sources(cues), &(&1.kind == :local_push and &1.enabled?))
    chosen = choose!(named, pushable)

    cond do
      chosen == [] ->
        Mix.raise(
          "There is no enabled local_push source in #{ConfigStore.path()}; add one under " <>
            "[fermix_core.cues.sources.<ref>] first."
        )

      length(chosen) > @max_sources ->
        Mix.raise(
          "At most #{@max_sources} sources: the daemon admits 50 items a second in all. " <>
            "Name them with --sources."
        )

      true ->
        chosen
    end
  end

  defp choose!(nil, pushable), do: pushable

  defp choose!(named, pushable) do
    by_ref = Map.new(pushable, &{&1.ref, &1})

    named
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> Enum.map(fn ref ->
      Map.get(by_ref, ref) ||
        Mix.raise("#{inspect(ref)} is not an enabled local_push source in #{ConfigStore.path()}.")
    end)
  end

  # A tree-less task has no command host, so the read says `supervised: false`.
  defp read_token(%{ref: ref, secrets: secrets}, profile) do
    case Map.fetch(secrets, :token) do
      {:ok, store} ->
        SecretWriter.get({:cue_source, ref, :token},
          store: store,
          profile: profile,
          supervised: false
        )

      :error ->
        {:error, :no_token_field}
    end
  end

  defp token!(token, source) do
    case token.(source) do
      {:ok, value} when is_binary(value) and value != "" ->
        value

      other ->
        Mix.raise(
          "The token of #{source.ref} could not be read: #{inspect(other)}. Store one with " <>
            "mix fermix.cues.secret #{source.ref} token."
        )
    end
  end

  defp run_id, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp probe!(plan, opts) do
    probe = Keyword.get(opts, :probe, &tcp_probe/1)

    case probe.(plan.port) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "Nothing answers on 127.0.0.1:#{plan.port} (#{inspect(reason)}); start the " <>
            "development daemon for this FERMIX_HOME with cues enabled first."
        )
    end
  end

  # The door is on loopback, which the egress policy always dials directly;
  # asking it first keeps this dial on the one policy every other one follows.
  defp tcp_probe(port) do
    with :ok <- Egress.ensure_direct("http://127.0.0.1:#{port}"),
         {:ok, socket} <-
           :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @probe_timeout_ms) do
      :gen_tcp.close(socket)
    end
  end

  defp intro(plan) do
    refs = Enum.map_join(plan.sources, ", ", & &1.ref)

    "Pushing #{plan.rate} items a second to each of #{length(plan.sources)} sources " <>
      "(#{refs}) for #{plan.seconds} s at 127.0.0.1:#{plan.port}. Every accepted item " <>
      "reaches the watchers that listen to these sources."
  end

  # --- driving -------------------------------------------------------------------

  @doc false
  @spec drive(map(), keyword()) :: map()
  def drive(plan, opts \\ []) when is_map(plan) and is_list(opts) do
    clock = monotonic(opts)
    wall = Keyword.get(opts, :wall_clock, &DateTime.utc_now/0)
    started_at = wall.()
    start_ms = clock.()
    stop_ms = start_ms + plan.seconds * 1_000 + @overrun_ms
    schedule = %{start_ms: start_ms, stop_ms: stop_ms}

    # Each task is bounded: it sends at most rate × seconds requests, each
    # bounded by the request timeout, and stops sending at `stop_ms`.
    per_source =
      plan.sources
      |> Enum.map(fn source ->
        Task.async(fn -> drive_source(source, plan, schedule, opts) end)
      end)
      |> Task.await_many(:infinity)

    %{
      per_source: per_source,
      totals: totals(per_source),
      window: %{from: started_at, to: wall.()}
    }
  end

  defp drive_source(source, plan, schedule, opts) do
    count = plan.rate * plan.seconds

    acc = %{
      ref: source.ref,
      planned: count,
      sent: 0,
      unsent: 0,
      outcomes: %{},
      latencies: [],
      max_late_ms: 0
    }

    Enum.reduce_while(0..(count - 1)//1, acc, fn index, acc ->
      due = schedule.start_ms + div(index * 1_000, plan.rate)

      if monotonic(opts).() > schedule.stop_ms,
        do: {:halt, %{acc | unsent: count - index}},
        else: {:cont, send_one(source, plan, index, due, acc, opts)}
    end)
  end

  defp send_one(source, plan, index, due, acc, opts) do
    clock = monotonic(opts)
    now = clock.()
    if due > now, do: sleep(opts).(due - now)
    sent_at = clock.()
    outcome = post(source, plan, index, opts)
    latency = clock.() - sent_at

    %{
      acc
      | sent: acc.sent + 1,
        outcomes: Map.update(acc.outcomes, label(outcome), 1, &(&1 + 1)),
        latencies: [latency | acc.latencies],
        max_late_ms: max(acc.max_late_ms, sent_at - due)
    }
  end

  defp post(source, plan, index, opts) do
    post = Keyword.get(opts, :post, &http_post/3)
    url = "http://127.0.0.1:#{plan.port}/cues/v1/#{source.ref}"
    headers = [{"content-type", @content_type}, {"authorization", "Bearer " <> source.token}]
    classify(post.(url, headers, Jason.encode!(event(source, plan, index))))
  end

  @doc false
  @spec event(map(), map(), non_neg_integer()) :: map()
  def event(source, plan, index) do
    %{
      "specversion" => "1.0",
      "id" => "load-#{plan.run_id}-#{source.ref}-#{index}",
      "source" => @event_source,
      "type" => @event_type,
      "data" => %{"run" => plan.run_id, "n" => index}
    }
  end

  # Routed like every other request the engine sends (loopback goes direct).
  defp http_post(url, headers, body) do
    [
      method: :post,
      url: url,
      headers: headers,
      body: body,
      retry: false,
      decode_body: false,
      receive_timeout: @request_timeout_ms
    ]
    |> Req.new()
    |> Egress.attach(:direct)
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status, body: answer}} -> {:ok, status, answer}
      {:error, exception} -> {:error, exception}
    end
  end

  # The door answers 200 (and 429 when no event got past a rate or budget)
  # with one result per event; a refusal before that is its HTTP status.
  defp classify({:ok, status, answer}) when status in [200, 429] do
    case Jason.decode(answer) do
      {:ok, %{"results" => [%{"status" => item_status}]}} -> {:item, item_status}
      _other -> {:http, status}
    end
  end

  defp classify({:ok, status, _answer}), do: {:http, status}
  defp classify({:error, reason}), do: {:transport, reason}

  defp label({:item, status}), do: status
  defp label({:http, status}), do: "http #{status}"
  defp label({:transport, %{reason: reason}}), do: "transport #{inspect(reason)}"
  defp label({:transport, reason}), do: "transport #{inspect(reason)}"

  defp totals(per_source) do
    %{
      planned: sum(per_source, :planned),
      sent: sum(per_source, :sent),
      unsent: sum(per_source, :unsent),
      accepted: Enum.reduce(per_source, 0, &(Map.get(&1.outcomes, "accepted", 0) + &2)),
      outcomes:
        Enum.reduce(per_source, %{}, &Map.merge(&2, &1.outcomes, fn _k, a, b -> a + b end)),
      latencies: Enum.flat_map(per_source, & &1.latencies),
      max_late_ms: per_source |> Enum.map(& &1.max_late_ms) |> Enum.max(fn -> 0 end)
    }
  end

  defp sum(rows, key), do: Enum.reduce(rows, 0, &(Map.fetch!(&1, key) + &2))

  defp monotonic(opts),
    do: Keyword.get(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)

  defp sleep(opts), do: Keyword.get(opts, :sleep, &Process.sleep/1)

  # --- the daemon's own traces ------------------------------------------------------

  @doc false
  @spec traced(map(), %{from: DateTime.t(), to: DateTime.t()}, keyword()) :: map()
  def traced(plan, %{from: from, to: to}, opts \\ []) do
    dir = Keyword.get_lazy(opts, :trace_dir, &FermixCore.Application.trace_dir/0)
    refs = MapSet.new(plan.sources, & &1.ref)
    files = trace_files(dir, from, to)
    acc = %{files: length(files), accept_ms: [], repo_timeouts: 0, unreadable: 0, capped?: false}

    # Lazy, so a large day file is read line by line, each closed once read,
    # and no further than the line cap.
    files
    |> Stream.flat_map(&lines/1)
    |> Stream.take(@max_trace_lines + 1)
    |> Stream.with_index()
    |> Enum.reduce(acc, fn {line, index}, acc -> fold_line(line, index, {from, to, refs}, acc) end)
  end

  defp trace_files(dir, from, to) do
    Date.range(DateTime.to_date(from), DateTime.to_date(to))
    |> Enum.map(&Path.join([dir, Date.to_iso8601(&1), "agent_event.jsonl"]))
    |> Enum.filter(&File.regular?/1)
  end

  defp lines(path), do: path |> File.stream!() |> Stream.map(&String.trim_trailing/1)

  defp fold_line(_line, index, _window, acc) when index >= @max_trace_lines,
    do: %{acc | capped?: true}

  defp fold_line(line, _index, window, acc) do
    case Jason.decode(line) do
      {:ok, row} when is_map(row) -> fold_row(row, window, acc)
      _other -> %{acc | unreadable: acc.unreadable + 1}
    end
  end

  defp fold_row(row, {from, to, refs}, acc) do
    cond do
      not in_window?(row, from, to) -> acc
      accepted_row?(row, refs) -> %{acc | accept_ms: [row["accept_ms"] | acc.accept_ms]}
      repo_timeout_row?(row) -> %{acc | repo_timeouts: acc.repo_timeouts + 1}
      true -> acc
    end
  end

  defp in_window?(%{"ts" => ts}, from, to) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, at, _offset} ->
        DateTime.compare(at, from) != :lt and
          DateTime.compare(at, DateTime.add(to, @trace_grace_ms, :millisecond)) != :gt

      {:error, _reason} ->
        false
    end
  end

  defp in_window?(_row, _from, _to), do: false

  defp accepted_row?(row, refs) do
    row["event"] == "cue_lifecycle" and row["phase"] == "accepted" and
      MapSet.member?(refs, row["source_ref"]) and is_integer(row["accept_ms"])
  end

  defp repo_timeout_row?(row), do: row["event"] == "timeout" and row["agent"] == "repo_call"

  # --- the report ----------------------------------------------------------------

  @doc false
  @spec report(map(), map(), map()) :: String.t()
  def report(plan, drive, traced) do
    [
      table(drive),
      refusals_line(drive.totals),
      "Each source sends one request at a time, so a slow answer delays its next send; " <>
        "the latest send was #{drive.totals.max_late_ms} ms behind its schedule.",
      daemon_lines(plan, drive, traced),
      "Not measured: the latency of job and reminder claims and settles and of message " <>
        "persistence. No telemetry carries them and this task never opens memory.db; only " <>
        "a Repo call past its #{Timeouts.repo_call()} ms budget shows, counted above for " <>
        "every caller."
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp table(drive) do
    header =
      row(["source", "sent", "accepted", "refused", "not sent", "p50", "p90", "p99", "max"])

    rows = Enum.map(drive.per_source, &source_row(&1.ref, &1))
    total = source_row("all", drive.totals)
    [header | rows] ++ [total, "(p50 to max: ms from send to the door's answer)"]
  end

  defp source_row(name, stats) do
    accepted = Map.get(stats.outcomes, "accepted", 0)
    [p50, p90, p99, max] = percentiles(stats.latencies)

    row([
      name,
      stats.sent,
      accepted,
      stats.sent - accepted,
      stats.unsent,
      p50,
      p90,
      p99,
      max
    ])
  end

  defp row([name | numbers]) do
    String.pad_trailing(to_string(name), 24) <>
      Enum.map_join(numbers, "", &String.pad_leading(to_string(&1), 10))
  end

  defp refusals_line(%{outcomes: outcomes}) do
    case outcomes |> Map.delete("accepted") |> Enum.sort() do
      [] -> "Refused: none."
      refused -> "Refused: " <> Enum.map_join(refused, ", ", fn {what, n} -> "#{what} #{n}" end)
    end
  end

  defp daemon_lines(_plan, _drive, %{files: 0}) do
    "Daemon side: no trace file for this window under the home's traces directory, so " <>
      "the daemon's own accept times and Repo timeouts were not read."
  end

  defp daemon_lines(_plan, drive, traced) do
    [p50, p90, p99, max] = percentiles(traced.accept_ms)
    traced_count = length(traced.accept_ms)

    [
      "Daemon side (its trace files for this window): #{traced_count} accepts traced " <>
        "for these sources (the door answered #{drive.totals.accepted}); accept_ms p50 " <>
        "#{p50}, p90 #{p90}, p99 #{p99}, max #{max}; #{traced.repo_timeouts} Repo calls ran " <>
        "past their budget.",
      trace_caveats(traced)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp trace_caveats(%{capped?: true}),
    do: "The trace files were read only up to #{@max_trace_lines} lines."

  defp trace_caveats(%{unreadable: n}) when n > 0, do: "#{n} trace lines could not be read."
  defp trace_caveats(_traced), do: nil

  @doc false
  @spec percentiles([non_neg_integer()]) :: [non_neg_integer() | String.t()]
  def percentiles([]), do: ["-", "-", "-", "-"]

  def percentiles(values) when is_list(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    rank = fn q -> Enum.at(sorted, max(ceil(q * count) - 1, 0)) end
    [rank.(0.5), rank.(0.9), rank.(0.99), List.last(sorted)]
  end
end
