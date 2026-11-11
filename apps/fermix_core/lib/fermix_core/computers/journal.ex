defmodule FermixCore.Computers.Journal do
  @moduledoc """
  A computer's journal of what its server asked of it (M97 §6.3): its own
  account, which the server cannot edit, read by the server after a lost
  answer (`invoke_status`) and by the owner at the computer
  (`computer.journal.list`, "What Fermix did on this computer").

  One file per UTC day under `<home>/device/invocations/`
  (`<YYYY-MM-DD>.jsonl`, `0600` under a `0700` directory; `device/` never
  travels with the home and no agent tool reaches it), one JSON record per
  line:

      {"v":1,"e":"started","id":"inv-…","at":"…","capability":"system","op":"echo",
       "target":"echo","origin":"chat","epoch":3,"turn_session":"main-4"}
      {"v":1,"e":"finished","id":"inv-…","at":"…","status":"ok","result_bytes":96,
       "duration_ms":2}

  A `started` record is written and synced to disk before the invocation
  runs, and a `finished` one before its answer goes. A request refused
  before it ran has only a `finished` record, which then names its
  capability, op, target and origin itself. A finished record may carry a
  `refusal` and a `note` (`interrupted`: the engine stopped while it ran).
  The journal never holds content: the target is a short description (a
  path, a host or an action). A request its capability says is no thing
  Fermix did on this computer (`Capability.recorded?/3`: the renewal of a
  screen hold, sent every 30 s while a server session holds the screen) has
  no record at all, so bookkeeping never pushes what Fermix did out of the
  bound below.

  A torn last line (a crash in the middle of a write) is skipped when read,
  logged once per read, and the next append starts on a fresh line.

  Retention (`prune/2`, at start and every hour): day files older than 7
  days go, then while more than #{2_000} invocations remain the oldest file
  is rewritten without its oldest (a temporary file, synced, renamed).
  `interrupted/2` closes, at start, every invocation a crash left started.

  Pure file I/O; `FermixChannels.Desktop.Invoke.Admission` is its one
  writer.
  """

  require Logger

  @version 1
  @dir_mode 0o700
  @file_mode 0o600
  @keep_days 7
  @max_invocations 2_000
  @default_limit 50
  @max_limit 200
  @day_file ~r/\A(\d{4}-\d{2}-\d{2})\.jsonl\z/

  @typedoc "A failure of the journal's I/O, naming the file."
  @type error :: {:file, Path.t(), File.posix() | term()}

  @typedoc "One invocation as the owner reads it."
  @type entry :: %{
          id: String.t(),
          at: String.t(),
          finished_at: String.t() | nil,
          capability: String.t() | nil,
          op: String.t() | nil,
          target: String.t() | nil,
          origin: String.t() | nil,
          status: String.t() | nil,
          refusal: String.t() | nil,
          result_bytes: non_neg_integer() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @doc "Where the journal lives under `home`."
  @spec dir(Path.t()) :: Path.t()
  def dir(home) when is_binary(home) and home != "",
    do: Path.join([home, "device", "invocations"])

  @doc "The most invocations the journal keeps."
  @spec max_invocations() :: pos_integer()
  def max_invocations, do: @max_invocations

  @doc """
  Appends and syncs a `started` record: `id`, `at`, `capability`, `op`,
  `target`, `origin`, `epoch` and `turn_session` (nil for none).
  """
  @spec append_started(Path.t(), map()) :: :ok | {:error, error()}
  def append_started(dir, %{id: id, at: %DateTime{} = at} = fields) when is_binary(id) do
    record =
      %{
        "v" => @version,
        "e" => "started",
        "id" => id,
        "at" => iso(at),
        "capability" => Map.fetch!(fields, :capability),
        "op" => Map.fetch!(fields, :op),
        "target" => Map.fetch!(fields, :target),
        "origin" => to_string(Map.fetch!(fields, :origin)),
        "epoch" => Map.fetch!(fields, :epoch)
      }
      |> put_some("turn_session", Map.get(fields, :turn_session))

    append(dir, at, record)
  end

  @doc """
  Appends and syncs a `finished` record: `id`, `at`, `status`, `result_bytes`
  and `duration_ms`, with `refusal` and `note` when set, and `capability`,
  `op`, `target` and `origin` for a request that never started.
  """
  @spec append_finished(Path.t(), map()) :: :ok | {:error, error()}
  def append_finished(dir, %{id: id, at: %DateTime{} = at, status: status} = fields)
      when is_binary(id) do
    record =
      %{
        "v" => @version,
        "e" => "finished",
        "id" => id,
        "at" => iso(at),
        "status" => to_string(status),
        "result_bytes" => Map.get(fields, :result_bytes, 0),
        "duration_ms" => Map.get(fields, :duration_ms, 0)
      }
      |> put_some("refusal", fields |> Map.get(:refusal) |> some_string())
      |> put_some("note", Map.get(fields, :note))
      |> put_some("capability", Map.get(fields, :capability))
      |> put_some("op", Map.get(fields, :op))
      |> put_some("target", Map.get(fields, :target))
      |> put_some("origin", fields |> Map.get(:origin) |> some_string())

    append(dir, at, record)
  end

  @doc "The invocation `id` as the journal holds it, or `:none`."
  @spec lookup(Path.t(), String.t()) :: {:ok, entry()} | :none | {:error, error()}
  def lookup(dir, id) when is_binary(dir) and is_binary(id) do
    with {:ok, records} <- read_all(dir) do
      case records |> Enum.filter(&(&1["id"] == id)) |> entries() do
        [entry] -> {:ok, entry}
        [] -> :none
      end
    end
  end

  @doc """
  The newest invocations first, at most `limit` (1 to #{@max_limit}, default
  #{@default_limit}), those older than the invocation `before` when it is
  given; `more` says whether older ones remain.
  """
  @spec list(Path.t(), keyword()) ::
          {:ok, %{entries: [entry()], more: boolean()}} | {:error, error()}
  def list(dir, opts \\ []) when is_binary(dir) and is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    true = is_integer(limit) and limit in 1..@max_limit

    with {:ok, records} <- read_all(dir) do
      newest = records |> entries() |> Enum.reverse() |> after_id(Keyword.get(opts, :before))
      {page, rest} = Enum.split(newest, limit)
      {:ok, %{entries: page, more: rest != []}}
    end
  end

  @doc """
  Retention (the moduledoc): drops day files older than #{@keep_days} days
  at `now`, then the oldest invocations past #{@max_invocations}.
  """
  @spec prune(Path.t(), DateTime.t()) :: :ok | {:error, error()}
  def prune(dir, %DateTime{} = now) when is_binary(dir) do
    with {:ok, days} <- day_files(dir),
         {:ok, kept} <- drop_old_days(dir, days, now),
         {:ok, by_day} <- read_days(dir, kept) do
      trim(dir, by_day)
    end
  end

  @doc """
  Closes every invocation the journal holds as started and never finished:
  a `finished` record with status `unknown` and the note `interrupted`, at
  `now`. Answers each one it closed, as `lookup/2` would read it now, oldest
  first.
  """
  @spec interrupted(Path.t(), DateTime.t()) :: {:ok, [entry()]} | {:error, error()}
  def interrupted(dir, %DateTime{} = now) when is_binary(dir) do
    with {:ok, records} <- read_all(dir) do
      open = for %{status: nil} = entry <- entries(records), do: entry
      close_all(dir, open, now)
    end
  end

  defp close_all(dir, open, now) do
    open
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, closed} ->
      fields = %{
        id: entry.id,
        at: now,
        status: :unknown,
        note: "interrupted",
        result_bytes: 0,
        duration_ms: max(DateTime.diff(now, parse!(entry.at), :millisecond), 0)
      }

      case append_finished(dir, fields) do
        :ok -> {:cont, {:ok, [closed_entry(entry, fields) | closed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, closed} -> {:ok, Enum.reverse(closed)}
      error -> error
    end)
  end

  defp closed_entry(entry, fields) do
    %{
      entry
      | finished_at: iso(fields.at),
        status: "unknown",
        result_bytes: 0,
        duration_ms: fields.duration_ms
    }
  end

  # -- writing ------------------------------------------------------------------

  defp append(dir, at, record) do
    path = Path.join(dir, day_name(at))
    line = Jason.encode!(record)

    case open_append(path) do
      {:ok, io} -> write_line(io, path, line)
      {:error, :enoent} -> append_in_new_dir(dir, path, line)
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  # The directory is made once, the first time a record finds none.
  defp append_in_new_dir(dir, path, line) do
    with :ok <- make_dir(dir) do
      case open_append(path) do
        {:ok, io} -> write_line(io, path, line)
        {:error, reason} -> {:error, {:file, path, reason}}
      end
    end
  end

  defp open_append(path) do
    fresh? = not File.exists?(path)

    with {:ok, io} <- :file.open(path, [:read, :append, :binary, :raw]) do
      owner_only(io, path, fresh?)
    end
  end

  defp owner_only(io, _path, false), do: {:ok, io}

  defp owner_only(io, path, true) do
    case :file.change_mode(path, @file_mode) do
      :ok ->
        {:ok, io}

      {:error, _reason} = error ->
        _closing = :file.close(io)
        error
    end
  end

  # A torn last line gets its end first, so this record starts on a line of
  # its own; then the record, synced before the caller goes on. The file is
  # closed on every path, and a failed close is the write's failure.
  defp write_line(io, path, line) do
    written =
      with {:ok, lead} <- line_start(io),
           :ok <- :file.write(io, [lead, line, "\n"]) do
        :file.sync(io)
      end

    closed(written, :file.close(io), path)
  end

  defp closed(:ok, :ok, _path), do: :ok
  defp closed({:error, reason}, _closed, path), do: {:error, {:file, path, reason}}
  defp closed(:ok, {:error, reason}, path), do: {:error, {:file, path, reason}}

  defp line_start(io) do
    case :file.position(io, :eof) do
      {:ok, 0} -> {:ok, ""}
      {:ok, size} -> last_byte(:file.pread(io, size - 1, 1))
      {:error, _reason} = error -> error
    end
  end

  defp last_byte({:ok, "\n"}), do: {:ok, ""}
  defp last_byte({:ok, _byte}), do: {:ok, "\n"}
  defp last_byte({:error, _reason} = error), do: error

  defp make_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, @dir_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  # -- reading ------------------------------------------------------------------

  defp read_all(dir) do
    with {:ok, days} <- day_files(dir),
         {:ok, by_day} <- read_days(dir, days) do
      {:ok, Enum.flat_map(by_day, fn {_day, records} -> records end)}
    end
  end

  # The day files, oldest first.
  defp day_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        {:ok, for(name <- Enum.sort(names), [_all, day] <- [Regex.run(@day_file, name)], do: day)}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:file, dir, reason}}
    end
  end

  defp read_days(dir, days) do
    Enum.reduce_while(days, {:ok, []}, fn day, {:ok, acc} ->
      path = Path.join(dir, day <> ".jsonl")

      case File.read(path) do
        {:ok, text} -> {:cont, {:ok, [{day, records(text, path)} | acc]}}
        {:error, :enoent} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:file, path, reason}}}
      end
    end)
    |> then(fn
      {:ok, by_day} -> {:ok, Enum.reverse(by_day)}
      error -> error
    end)
  end

  defp records(text, path) do
    {records, torn} =
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce({[], 0}, fn line, {acc, torn} ->
        case Jason.decode(line) do
          {:ok, %{"v" => @version, "id" => id, "e" => e} = record}
          when is_binary(id) and e in ["started", "finished"] ->
            {[record | acc], torn}

          _torn_or_unknown ->
            {acc, torn + 1}
        end
      end)

    if torn > 0, do: Logger.warning("the invocation journal #{path}: #{torn} line(s) skipped")
    Enum.reverse(records)
  end

  # One entry per invocation, oldest first by when it opened.
  defp entries(records) do
    {order, by_id} =
      Enum.reduce(records, {[], %{}}, fn record, {order, by_id} ->
        id = record["id"]
        order = if Map.has_key?(by_id, id), do: order, else: [id | order]
        {order, Map.update(by_id, id, [record], &(&1 ++ [record]))}
      end)

    order
    |> Enum.reverse()
    |> Enum.map(&entry(&1, Map.fetch!(by_id, &1)))
  end

  defp entry(id, records) do
    started = Enum.find(records, &(&1["e"] == "started"))
    finished = Enum.find(records, &(&1["e"] == "finished"))
    opened = started || finished

    %{
      id: id,
      at: opened["at"],
      finished_at: finished && finished["at"],
      capability: opened["capability"],
      op: opened["op"],
      target: opened["target"],
      origin: opened["origin"],
      status: finished && finished["status"],
      refusal: finished && finished["refusal"],
      result_bytes: finished && finished["result_bytes"],
      duration_ms: finished && finished["duration_ms"]
    }
  end

  defp after_id(newest, nil), do: newest

  defp after_id(newest, before) when is_binary(before) do
    case Enum.split_while(newest, &(&1.id != before)) do
      {_newer, [_before | older]} -> older
      {_all, []} -> []
    end
  end

  # -- retention ----------------------------------------------------------------

  defp drop_old_days(dir, days, now) do
    oldest_kept = now |> DateTime.to_date() |> Date.add(1 - @keep_days) |> Date.to_iso8601()
    {old, kept} = Enum.split_with(days, &(&1 < oldest_kept))

    Enum.reduce_while(old, {:ok, kept}, fn day, acc ->
      path = Path.join(dir, day <> ".jsonl")

      case File.rm(path) do
        :ok -> {:cont, acc}
        {:error, :enoent} -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, {:file, path, reason}}}
      end
    end)
  end

  # The oldest invocations past the bound go, from the oldest files.
  defp trim(dir, by_day) do
    ids = by_day |> Enum.flat_map(&elem(&1, 1)) |> Enum.map(& &1["id"]) |> Enum.uniq()
    excess = length(ids) - @max_invocations

    if excess > 0,
      do: rewrite_without(dir, by_day, MapSet.new(Enum.take(ids, excess))),
      else: :ok
  end

  defp rewrite_without(dir, by_day, dropped) do
    Enum.reduce_while(by_day, :ok, fn {day, records}, :ok ->
      case rewrite_day(Path.join(dir, day <> ".jsonl"), records, dropped) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp rewrite_day(path, records, dropped) do
    kept = Enum.reject(records, &MapSet.member?(dropped, &1["id"]))

    cond do
      length(kept) == length(records) -> :ok
      kept == [] -> remove(path)
      true -> rewrite(path, kept)
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp rewrite(path, records) do
    temp = path <> ".tmp"
    body = Enum.map(records, &[Jason.encode!(&1), "\n"])

    with {:ok, io} <- :file.open(temp, [:write, :binary, :raw]),
         :ok <- write_synced(io, body),
         :ok <- :file.change_mode(temp, @file_mode),
         :ok <- :file.rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("the invocation journal #{path} was not rewritten: #{inspect(reason)}")
        _gone = File.rm(temp)
        {:error, {:file, path, reason}}
    end
  end

  defp write_synced(io, body) do
    written = with :ok <- :file.write(io, body), do: :file.sync(io)

    case {written, :file.close(io)} do
      {:ok, closed} -> closed
      {{:error, _reason} = error, _closed} -> error
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp day_name(at), do: (at |> DateTime.to_date() |> Date.to_iso8601()) <> ".jsonl"

  defp iso(at), do: at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp parse!(at) do
    {:ok, parsed, 0} = DateTime.from_iso8601(at)
    parsed
  end

  defp some_string(nil), do: nil
  defp some_string(value), do: to_string(value)

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)
end
