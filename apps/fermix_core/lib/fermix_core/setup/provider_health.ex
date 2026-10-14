defmodule FermixCore.Setup.ProviderHealth do
  @moduledoc """
  Whether the primary provider has been answering, judged from the calls Fermix
  already made: the `llm_call` rows `FermixCore.Trace` writes for every
  `[:fermix, :provider, :call]`. No request is sent, so the local Doctor can ask
  it on every run (`Fermix.CLI.Doctor.Checks.provider_health/1` renders it).

  `read/3` is the bounded file read and `summarize/3` the pure judgement.

  ## Which rows count

  A row counts when its `provider` is the primary provider, it is a model call,
  and its `status` is one of these:

    * `ok`: a call that succeeded. Every writer uses it.
    * `error`: a call that failed. The model adapters add `error_kind` (and
      `error_status`, `error`) through `Providers.Error.telemetry_metadata/1`;
      the model listing (`adapter: model_listing`) adds only its own `error`
      text. The listing is a real call to the provider, so it counts.
    * `server_error`, `network`, `auth_scope_mismatch`: the failures of the
      app's provider probe (`Management.Providers`), which records the probe's
      own error tag as its status.

  Left out:

    * `misconfigured`, the probe's refusal before it sent anything.
    * The image and voice-note calls. `Tools.Media.Support` and
      `Transcription.Support` record the provider itself as their `adapter`.
      They are not model calls, they have Doctor rows of their own, and their
      failures are mostly about the request: a format or a prompt the API
      refused.
    * A failure whose `error_kind` is about the request or about this machine
      rather than the provider: `context_length` and `invalid_request` (the
      provider refused this one request), `not_implemented` (no adapter, so no
      request), and `connection_unavailable`, `proxy_unreachable` and
      `proxy_refused` (this machine's connection pool or proxy, which every
      provider shares; `Providers.Failover` refuses to fail over on them for the
      same reason).

  Every other kind counts: `provider_unavailable`, `timeout`, `rate_limit`,
  `quota`, `auth`, `plan_not_eligible`, `network`, `transport`,
  `transport_closed` and the catch-all `provider`. Each says the provider did
  not serve this account's call. No adapter records a cancelled call, so there
  is nothing to leave out for one.

  ## Bounds

  At most the last 20 counted calls, within the last 24 hours. Only today's
  and, when today's holds fewer than that, yesterday's (UTC) `llm_call.jsonl`
  are read, each from its tail and at most 1 MiB of it: content capture can put
  whole prompts in a row.
  """

  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.Error, as: ProviderError

  # The two caps on what is judged: the last 20 counted calls, none older than
  # 24 hours. The newest calls say the most about the provider now.
  @max_calls 20
  @window_seconds 86_400
  # The most read from each day's file, from its tail.
  @max_bytes_per_file 1_048_576
  # The longest `error` text quoted on the latest failure's line.
  @max_quoted_bytes 300

  @failure_statuses ~w(error server_error network auth_scope_mismatch)
  @excluded_kinds ~w(context_length invalid_request not_implemented connection_unavailable
                     proxy_unreachable proxy_refused)

  @type verdict :: {:ok | :warn | :fail, String.t()}
  @type read_result :: %{rows: [map()], undecodable: non_neg_integer()}

  @doc """
  The verdict on `provider` from trace rows, as of `now`.

  `:ok` when there were no calls or the latest succeeded; `:warn` when the
  latest failed but it was the only call or an earlier one succeeded, since one
  failure can be a blip; `:fail` when every call, at least two, failed.
  """
  @spec summarize([map()], atom(), DateTime.t()) :: verdict()
  def summarize(rows, provider, %DateTime{} = now) when is_list(rows) and is_atom(provider) do
    label = Descriptor.fetch!(provider).label

    case calls(rows, provider, now) do
      [] -> {:ok, "no calls to #{label} in the last 24 hours"}
      calls -> judge(calls, label, now)
    end
  end

  @doc """
  The rows of today's `llm_call.jsonl` under `trace_dir`, preceded by
  yesterday's when today's holds fewer than the calls `summarize/3` weighs.

  Each file is read from its tail. When the cap cuts into a file, the first,
  partial line is dropped by design; any other line that is not a JSON object
  is counted in `undecodable`. A missing directory or file is no rows; any
  other read error is returned with the path it happened on.
  """
  @spec read(Path.t(), atom(), DateTime.t()) ::
          {:ok, read_result()} | {:error, {Path.t(), atom()}}
  def read(trace_dir, provider, %DateTime{} = now)
      when is_binary(trace_dir) and is_atom(provider) do
    today = DateTime.to_date(now)

    with {:ok, recent} <- read_day(trace_dir, today) do
      if length(calls(recent.rows, provider, now)) >= @max_calls,
        do: {:ok, recent},
        else: prepend_day(recent, trace_dir, Date.add(today, -1))
    end
  end

  # --- judgement ---

  defp calls(rows, provider, now) do
    name = Atom.to_string(provider)

    rows
    |> Enum.filter(&(&1["provider"] == name and outcome(&1) != :left_out))
    |> Enum.flat_map(&timed/1)
    |> Enum.filter(fn {at, _row} -> DateTime.diff(now, at) < @window_seconds end)
    |> Enum.sort_by(fn {at, _row} -> at end, DateTime)
    |> Enum.take(-@max_calls)
  end

  # A span that names the provider as its own adapter is an image or a voice
  # note, not a model call.
  defp outcome(%{"provider" => provider, "adapter" => provider}), do: :left_out
  defp outcome(%{"status" => "ok"}), do: :ok

  defp outcome(%{"status" => status} = row) when status in @failure_statuses,
    do: if(row["error_kind"] in @excluded_kinds, do: :left_out, else: :failed)

  defp outcome(_row), do: :left_out

  defp timed(%{"ts" => ts} = row) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, at, _offset} -> [{at, row}]
      {:error, _reason} -> []
    end
  end

  defp timed(_row), do: []

  defp judge(calls, label, now) do
    {latest_at, latest} = List.last(calls)
    total = length(calls)
    failed = Enum.count(calls, fn {_at, row} -> outcome(row) == :failed end)
    ago = ago(DateTime.diff(now, latest_at))

    cond do
      outcome(latest) == :ok ->
        {:ok, "the latest call to #{label} succeeded #{ago}" <> failed_share(failed, total)}

      failed == total and total >= 2 ->
        {first_at, _first} = hd(calls)
        span = span(DateTime.diff(now, first_at))

        {:fail,
         "#{label}: all #{total} calls in the last #{span} failed; " <>
           "the latest got #{failure(latest)}"}

      total == 1 ->
        {:warn,
         "the only call to #{label} in the last 24 hours failed #{ago} " <>
           "and got #{failure(latest)}"}

      true ->
        {:warn,
         "#{failed} of the last #{total} calls to #{label} failed, including the latest " <>
           "#{ago}, which got #{failure(latest)}"}
    end
  end

  defp failed_share(0, _total), do: ""
  defp failed_share(failed, total), do: "; #{failed} of the last #{total} failed"

  # The latest failure in one line, from its status and kind, plus its own text
  # only when that is one plain line. A row written before `Providers.Error`
  # rendered pages as a sentence still carries the page, so a status row's text
  # goes through that same sentence and a page is never quoted.
  defp failure(%{"error_status" => status} = row) when is_integer(status) and status > 0 do
    text = row |> Map.get("error") |> quotable(status)

    if is_binary(text) and String.starts_with?(text, "HTTP #{status}"),
      do: text,
      else: "HTTP #{status}" <> colon(text)
  end

  defp failure(%{"error_kind" => kind} = row) when is_binary(kind) do
    "an error (#{String.replace(kind, "_", " ")})" <> colon(quotable(row["error"], nil))
  end

  defp failure(row), do: quotable(row["error"], nil) || "an error"

  defp quotable(text, status) when is_binary(text) and is_integer(status),
    do: status |> ProviderError.status_message(text) |> plain_line()

  defp quotable(text, nil) when is_binary(text), do: plain_line(text)
  defp quotable(_text, _status), do: nil

  defp plain_line(text) do
    line = String.trim(text)
    if plain?(line), do: line
  end

  defp plain?(line) do
    line != "" and byte_size(line) <= @max_quoted_bytes and
      not String.contains?(line, ["\n", "\r", "<"])
  end

  defp colon(nil), do: ""
  defp colon(text), do: ": " <> text

  defp ago(seconds) when seconds < 60, do: "less than a minute ago"
  defp ago(seconds) when seconds < 3600, do: count(div(seconds, 60), "minute") <> " ago"
  defp ago(seconds), do: count(div(seconds, 3600), "hour") <> " ago"

  # Rounded up, so "the last 41 minutes" never leaves out the oldest call.
  defp span(seconds) when seconds <= 60, do: "minute"
  defp span(seconds) when seconds <= 3600, do: count(ceil_div(seconds, 60), "minute")
  defp span(seconds), do: count(min(ceil_div(seconds, 3600), 24), "hour")

  defp ceil_div(seconds, unit), do: div(seconds + unit - 1, unit)

  defp count(1, unit), do: "1 #{unit}"
  defp count(n, unit), do: "#{n} #{unit}s"

  # --- reading ---

  defp prepend_day(recent, trace_dir, date) do
    with {:ok, earlier} <- read_day(trace_dir, date) do
      {:ok,
       %{
         rows: earlier.rows ++ recent.rows,
         undecodable: earlier.undecodable + recent.undecodable
       }}
    end
  end

  defp read_day(trace_dir, date) do
    path = Path.join([trace_dir, Date.to_iso8601(date), "llm_call.jsonl"])

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> read_tail(path, size)
      {:error, :enoent} -> {:ok, %{rows: [], undecodable: 0}}
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp read_tail(path, size) do
    offset = max(size - @max_bytes_per_file, 0)

    case File.open(path, [:read, :binary], &:file.pread(&1, offset, size - offset)) do
      {:ok, {:ok, data}} -> {:ok, decode(data, offset > 0)}
      {:ok, :eof} -> {:ok, %{rows: [], undecodable: 0}}
      {:ok, {:error, reason}} -> {:error, {path, reason}}
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp decode(data, cut?) do
    lines = String.split(data, "\n")
    lines = if cut?, do: tl(lines), else: lines
    record = Enum.reduce(lines, %{rows: [], undecodable: 0}, &decode_line/2)

    %{record | rows: Enum.reverse(record.rows)}
  end

  defp decode_line(line, record), do: line |> String.trim() |> add_row(record)

  defp add_row("", record), do: record

  defp add_row(text, record) do
    case Jason.decode(text) do
      {:ok, row} when is_map(row) -> %{record | rows: [row | record.rows]}
      _undecodable -> %{record | undecodable: record.undecodable + 1}
    end
  end
end
