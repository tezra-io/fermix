defmodule FermixCore.Management.Logs do
  @moduledoc """
  Bounded queries over the daemon's rotated log set, behind `logs.query`
  (M34 §5 "Logs").

  The app never reads log files: it asks the daemon, which owns the rotation
  policy (`config/config.exs` `[:fermix_core, :log]` `max_no_bytes` /
  `max_no_files`) and the redactor. The set scanned here is resolved through
  `FermixCore.Application.default_log_file/0` and
  `FermixCore.Application.log_max_no_files/0` — the same two functions the
  handler installs itself with, so the reader can never scan fewer archives
  than are retained. Every bound M34 names is enforced here — a
  200-entry default tail, a 500-entry request ceiling, a 256 KiB encoded result
  cap, a 256-character search, and an opaque cursor that reports
  `cursor_expired` rather than silently returning a different window after the
  set rotates.

  `FermixCore.Log.RedactingFormatter.redact/1` runs again on every returned
  message. The formatter already redacted on write, but a line written before a
  pattern existed is still on disk, and the app must never be the first reader
  of an unredacted credential.

  Two shapes of the on-disk format constrain what this can offer:

  - **Subsystem** is not a field. The file handler's template is
    `[:time, " ", :level, " ", :msg]`, so the only subsystem signal a line can
    carry is a leading `[tag]` the message itself wrote. The filter matches that
    tag; a line without one has `subsystem: nil` and is excluded whenever a
    subsystem filter is supplied. (M34 §5 asks for a subsystem filter; the
    engine's log format carries no module or subsystem field. Recorded rather
    than resolved by changing the on-disk format under existing installs.)
  - **Cursor anchors count back from the newest entry**, because reading is
    bounded to a tail of each file and a full scan of the rotated set is not.
    Entries appended between two pages therefore shift the window by that many
    entries; rotation, the case M34 names, is detected exactly.

  An unreadable file is `{:error, :unreadable}`, never an empty page. "The
  daemon has written nothing" is a normal state this module reports as an empty
  result, so collapsing EACCES or EIO into the same answer would hide a fault
  behind a state that looks healthy — and a partially-read set would report the
  honest end of the page while entries still exist behind the failure.
  """

  require Logger

  alias FermixCore.Log.RedactingFormatter
  alias FermixCore.Management.Text

  @default_limit 200
  @max_limit 500
  @max_result_bytes 262_144
  @max_search_length 256
  @max_files 10
  @max_file_scan_bytes 2_097_152
  @max_message_bytes 4_096
  @max_continuation_lines 20
  @directions ~w(backward forward)
  @levels ~w(emergency alert critical error warning notice info debug)
  @param_keys ~w(limit level subsystem search direction cursor)
  @entry_pattern ~r/^(?<time>\S+)\s+(?<level>[a-z]+)\s+(?<message>.*)$/s
  @subsystem_pattern ~r/^\[(?<subsystem>[A-Za-z0-9_.:-]{1,64})\]/

  @type entry :: %{String.t() => term()}
  @type result :: %{String.t() => term()}

  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @spec max_result_bytes() :: pos_integer()
  def max_result_bytes, do: @max_result_bytes

  @doc """
  Runs one bounded log query.

  `params` are the wire parameters (`limit`, `level`, `subsystem`, `search`,
  `direction`, `cursor`). A missing log set is an empty page, not an error — a
  daemon that has not written a line yet is a normal state. A log file that
  exists and cannot be read is `{:error, :unreadable}`: returning an empty page
  there would be indistinguishable from that normal state.
  """
  @spec query(map(), keyword()) ::
          {:ok, result()} | {:error, :invalid_params | :cursor_expired | :unreadable}
  def query(params, opts \\ []) when is_map(params) and is_list(opts) do
    log_file = Keyword.get(opts, :log_file, configured_log_file())
    files = rotated_files(log_file, Keyword.get(opts, :max_no_files, configured_max_files()))

    with {:ok, request} <- parse(params),
         {:ok, anchor} <- resolve_anchor(request, files) do
      page(request, anchor, files)
    end
  end

  defp parse(params) do
    with :ok <- reject_unknown(params),
         {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, level} <- parse_level(Map.get(params, "level")),
         {:ok, subsystem} <- parse_text(Map.get(params, "subsystem"), 64),
         {:ok, search} <- parse_text(Map.get(params, "search"), @max_search_length),
         {:ok, direction} <- parse_direction(Map.get(params, "direction")) do
      {:ok,
       %{
         limit: limit,
         level: level,
         subsystem: subsystem,
         search: search && String.downcase(search),
         direction: direction,
         cursor: Map.get(params, "cursor")
       }}
    end
  end

  defp reject_unknown(params) do
    if Enum.all?(Map.keys(params), &(&1 in @param_keys)), do: :ok, else: {:error, :invalid_params}
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(limit) when is_integer(limit) and limit >= 1 and limit <= @max_limit,
    do: {:ok, limit}

  defp parse_limit(_limit), do: {:error, :invalid_params}

  defp parse_level(nil), do: {:ok, nil}
  defp parse_level(level) when level in @levels, do: {:ok, String.to_existing_atom(level)}
  defp parse_level(_level), do: {:error, :invalid_params}

  defp parse_text(nil, _maximum), do: {:ok, nil}

  defp parse_text(text, maximum)
       when is_binary(text) and byte_size(text) > 0 and byte_size(text) <= maximum,
       do: {:ok, text}

  defp parse_text(_text, _maximum), do: {:error, :invalid_params}

  defp parse_direction(nil), do: {:ok, "backward"}
  defp parse_direction(direction) when direction in @directions, do: {:ok, direction}
  defp parse_direction(_direction), do: {:error, :invalid_params}

  # The anchor is the number of matching entries, counted back from the newest,
  # that precede this page. A cursor carries that anchor plus the rotation
  # fingerprint it was minted against.
  defp resolve_anchor(%{cursor: nil, direction: "backward"}, _files), do: {:ok, 0}
  defp resolve_anchor(%{cursor: nil, direction: "forward"}, _files), do: {:error, :invalid_params}

  defp resolve_anchor(%{cursor: cursor} = request, files) do
    with {:ok, decoded} <- decode_cursor(cursor),
         :ok <- verify_fingerprint(decoded, files) do
      {:ok, anchor_for(request.direction, decoded["anchor"], request.limit)}
    end
  end

  defp anchor_for("backward", anchor, _limit), do: anchor
  defp anchor_for("forward", anchor, limit), do: max(anchor - limit, 0)

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"anchor" => anchor, "fingerprint" => fingerprint}} when is_integer(anchor) <-
           Jason.decode(json),
         true <- anchor >= 0 and is_integer(fingerprint) do
      {:ok, %{"anchor" => anchor, "fingerprint" => fingerprint}}
    else
      _invalid -> {:error, :invalid_params}
    end
  end

  defp decode_cursor(_cursor), do: {:error, :invalid_params}

  defp verify_fingerprint(%{"fingerprint" => fingerprint}, files) do
    if fingerprint == fingerprint(files), do: :ok, else: {:error, :cursor_expired}
  end

  defp page(request, anchor, files) do
    # One extra match is gathered so "are there older entries" is answered from
    # evidence rather than from the page being exactly full.
    with {:ok, matches} <- collect(files, request, anchor + request.limit + 1) do
      {:ok, render_page(request, anchor, matches, files)}
    end
  end

  defp render_page(request, anchor, matches, files) do
    window = matches |> Enum.drop(anchor) |> Enum.take(request.limit)
    {kept, truncated?} = cap_bytes(window)

    %{
      "entries" => Enum.reverse(kept),
      "count" => length(kept),
      "truncated" => truncated?,
      "direction" => request.direction,
      "cursor" => next_cursor(request.direction, anchor, kept, matches, files)
    }
  end

  # The cursor is the anchor for the next page in the SAME direction. A nil
  # cursor is the honest end of the set in that direction, not a client guess.
  defp next_cursor("backward", anchor, kept, matches, files) do
    consumed = anchor + length(kept)
    if length(matches) > consumed, do: encode_cursor(consumed, files), else: nil
  end

  defp next_cursor("forward", 0, _kept, _matches, _files), do: nil
  defp next_cursor("forward", anchor, _kept, _matches, files), do: encode_cursor(anchor, files)

  defp encode_cursor(anchor, files) do
    %{"anchor" => anchor, "fingerprint" => fingerprint(files)}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  # Entries are gathered newest-first and capped by encoded size, so an
  # oversized page drops its OLDEST rows and always returns the newest. The
  # two-byte seed is the JSON array's own brackets.
  defp cap_bytes(entries) do
    {kept, _size, truncated?} = Enum.reduce(entries, {[], 2, false}, &take_within_cap/2)
    {Enum.reverse(kept), truncated?}
  end

  defp take_within_cap(_entry, {kept, size, true}), do: {kept, size, true}

  defp take_within_cap(entry, {kept, size, false}) do
    next = size + byte_size(Jason.encode!(entry)) + 1

    if next > @max_result_bytes do
      {kept, size, true}
    else
      {[entry | kept], next, false}
    end
  end

  # Walks the rotated set newest-first and stops as soon as `needed` matching
  # entries exist, so a query never reads the whole retained history. A read
  # failure halts the walk: a short list would otherwise present itself as the
  # honest end of the set while entries still exist behind the unreadable file.
  defp collect(files, request, needed) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case matching_entries(file, request) do
        {:ok, entries} -> take_until_enough(acc ++ entries, needed)
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp take_until_enough(acc, needed) when length(acc) >= needed, do: {:halt, {:ok, acc}}
  defp take_until_enough(acc, _needed), do: {:cont, {:ok, acc}}

  defp matching_entries(file, request) do
    with {:ok, contents, partial?} <- read_tail(file) do
      entries =
        contents
        |> String.split("\n")
        |> drop_partial_line(partial?)
        |> to_entries()
        |> Enum.filter(&matches?(&1, request))
        |> Enum.reverse()

      {:ok, entries}
    end
  end

  defp read_tail(file) do
    case File.stat(file) do
      {:ok, %File.Stat{size: size}} when size <= @max_file_scan_bytes -> read_all(file)
      {:ok, %File.Stat{size: size}} -> read_last_bytes(file, size)
      {:error, reason} -> unreadable(file, :stat, reason)
    end
  end

  defp read_all(file) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents, false}
      {:error, reason} -> unreadable(file, :read, reason)
    end
  end

  defp read_last_bytes(file, size) do
    case :file.open(file, [:read, :binary]) do
      {:ok, io} -> read_from(file, io, size - @max_file_scan_bytes)
      {:error, reason} -> unreadable(file, :open, reason)
    end
  end

  defp read_from(file, io, offset) do
    result = :file.pread(io, offset, @max_file_scan_bytes)
    :ok = :file.close(io)

    case result do
      {:ok, contents} -> {:ok, contents, true}
      :eof -> {:ok, "", true}
      {:error, reason} -> unreadable(file, :pread, reason)
    end
  end

  # Loud, and with the operation that failed: an unreadable log is a fault the
  # operator has to fix, and the page it produced would look like silence.
  defp unreadable(file, operation, reason) do
    Logger.warning("logs.query could not #{operation} #{Path.basename(file)}: #{inspect(reason)}")

    {:error, :unreadable}
  end

  # The first line of a mid-file tail is almost certainly cut; a partial line is
  # not an entry and must not become one. A fully read file has no cut line.
  defp drop_partial_line(lines, false), do: lines
  defp drop_partial_line([_cut | rest], true), do: rest
  defp drop_partial_line([], true), do: []

  defp to_entries(lines) do
    lines
    |> Enum.reduce([], &fold_line/2)
    |> Enum.reverse()
    |> Enum.map(&finish_entry/1)
  end

  defp fold_line("", entries), do: entries

  defp fold_line(line, entries) do
    case Regex.named_captures(@entry_pattern, line) do
      %{"level" => level} = captures when level in @levels -> [new_entry(captures) | entries]
      _continuation -> append_continuation(entries, line)
    end
  end

  defp new_entry(%{"time" => time, "level" => level, "message" => message}) do
    %{time: time, level: level, message: message, continuations: 0}
  end

  # A stack trace or crash report spans lines; joining them keeps one event one
  # entry instead of turning a crash into twenty level-less rows.
  defp append_continuation([], _line), do: []

  defp append_continuation([%{continuations: count} = entry | rest], _line)
       when count >= @max_continuation_lines,
       do: [entry | rest]

  defp append_continuation([entry | rest], line) do
    [
      %{entry | message: entry.message <> "\n" <> line, continuations: entry.continuations + 1}
      | rest
    ]
  end

  defp finish_entry(entry) do
    message =
      entry.message
      |> RedactingFormatter.redact()
      |> Text.truncate(@max_message_bytes)

    %{
      "time" => entry.time,
      "level" => entry.level,
      "subsystem" => subsystem(message),
      "message" => message
    }
  end

  defp subsystem(message) do
    case Regex.named_captures(@subsystem_pattern, message) do
      %{"subsystem" => subsystem} -> subsystem
      nil -> nil
    end
  end

  defp matches?(entry, request) do
    level_at_least?(entry, request.level) and subsystem_matches?(entry, request.subsystem) and
      search_matches?(entry, request.search)
  end

  defp level_at_least?(_entry, nil), do: true

  defp level_at_least?(entry, minimum) do
    :logger.compare_levels(String.to_existing_atom(entry["level"]), minimum) in [:gt, :eq]
  end

  defp subsystem_matches?(_entry, nil), do: true
  defp subsystem_matches?(entry, subsystem), do: entry["subsystem"] == subsystem

  defp search_matches?(_entry, nil), do: true

  defp search_matches?(entry, search) do
    entry["message"] |> String.downcase() |> String.contains?(search)
  end

  # The rotated set newest-first: the live file, then `<file>.0`, `<file>.1`, …
  # `:logger_std_h` with `max_no_files: N` retains N archives named `.0` through
  # `.(N-1)`, so the last index is N-1 — stopping at N-2 hides the oldest
  # retained file and reports its absence as the end of the set.
  defp rotated_files(log_file, max_no_files) do
    archives_kept = max_no_files |> max(0) |> min(@max_files)
    archives = for index <- 0..(archives_kept - 1)//1, do: "#{log_file}.#{index}"
    Enum.filter([log_file | archives], &File.regular?/1)
  end

  # Rotation renames the live file onto `<file>.0`, so the newest archive's
  # inode changes exactly when the set rotates — and only then.
  defp fingerprint(files) do
    signature =
      files
      |> Enum.drop(1)
      |> Enum.map(fn file ->
        case File.stat(file) do
          {:ok, %File.Stat{inode: inode}} -> inode
          {:error, _reason} -> 0
        end
      end)

    :erlang.phash2({length(files), signature})
  end

  # One resolver: the same `[:fermix_core, :log]` keys and the same default path
  # `FermixCore.Application` gives `:logger_std_h` when it installs the handler.
  defp configured_log_file do
    :fermix_core
    |> Application.get_env(:log, [])
    |> Keyword.get_lazy(:file, &FermixCore.Application.default_log_file/0)
  end

  defp configured_max_files, do: FermixCore.Application.log_max_no_files()
end
