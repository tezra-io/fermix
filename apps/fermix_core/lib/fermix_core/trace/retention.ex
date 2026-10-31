defmodule FermixCore.Trace.Retention do
  @max_age_days 14
  @body_max_age_days 1
  @max_bytes 1_073_741_824
  @max_removals 32
  @bodies_suffix ".bodies.jsonl"

  @moduledoc """
  Keeps the trace store bounded on every machine (M75 L14): traces hold full
  request bodies, and an engine that never stops must never fill its disk.

  `FermixCore.Trace` writes one folder per UTC day under its directory
  (`<home>/traces/YYYY-MM-DD/`). A pass removes whole day folders, oldest
  first:

    * every day more than #{@max_age_days} days before today;
    * then the oldest days until the rest, today's included, fit in
      #{div(@max_bytes, 1_073_741_824)} GiB;
    * at most #{@max_removals} days in one pass; the next pass carries on.

  The bounds are internal constants (`limits/0`), not settings. A pass never
  removes today's folder, which holds the files `Trace` has open, nor a day
  after today (a clock set back), nor anything but a day of traces: a
  directory, never a link, named exactly as an ISO date and holding only
  `.jsonl` files and hidden ones (a Finder's `.DS_Store`), so a dated folder
  of something else in a directory `FERMIX_TRACE_DIR` names stays, and does
  not count toward the size. A day it cannot list, size or remove is named in
  the report's `refused` with the reason; while a day cannot be sized, the
  pass removes nothing for size. `Trace` runs a pass
  at its start and every hour, after closing the files of earlier days.

  **Bodies.** On an Always On server `Trace` writes the bodies of a record
  (a prompt, a reply, a tool's input or output) to the day's
  `<type>.bodies.jsonl` beside its records (M75 L20). `prune_bodies/3`,
  which `Trace` runs before `prune/3`, removes those files from every day
  more than #{@body_max_age_days} day before today, so a server keeps bodies
  through yesterday and the records #{@max_age_days} days. Elsewhere no day
  holds one, and the pass removes nothing. It keeps to the same days of
  traces and to #{@max_removals} days a pass, leaves a day past the age bound
  to `prune/3`, and refuses by name a file it cannot remove.
  """

  @type limits :: %{
          max_age_days: non_neg_integer(),
          body_max_age_days: non_neg_integer(),
          max_bytes: non_neg_integer(),
          max_removals: pos_integer()
        }
  @type report :: %{removed: [Date.t()], refused: [{Path.t(), term()}]}

  @doc """
  The bounds a pass keeps: days of age, days of age for bodies, total bytes,
  and days removed in one pass.
  """
  @spec limits() :: limits()
  def limits,
    do: %{
      max_age_days: @max_age_days,
      body_max_age_days: @body_max_age_days,
      max_bytes: @max_bytes,
      max_removals: @max_removals
    }

  @doc """
  One pass over `trace_dir` for the UTC date `today`: removes what the bounds
  say, oldest first, and reports the days removed and what it refused. A
  directory not made yet is an empty pass; the filesystem root is refused.
  """
  @spec prune(Path.t(), Date.t(), limits()) :: report()
  def prune(trace_dir, %Date{} = today, limits \\ limits())
      when is_binary(trace_dir) and is_map(limits) do
    case days(Path.expand(trace_dir)) do
      {:ok, days, refused} ->
        days
        |> plan(today, limits)
        |> remove(today, refused)

      {:error, path, reason} ->
        %{removed: [], refused: [{path, reason}]}
    end
  end

  @doc """
  One bodies pass over `trace_dir` for the UTC date `today`: removes the
  `<type>.bodies.jsonl` files of each day more than `body_max_age_days`
  before it and within `max_age_days`, oldest first, and reports the days
  whose bodies it removed and each file it could not remove. A directory or
  a day it cannot list is left to `prune/3`, which runs in the same pass and
  names it, so a failure is reported once.
  """
  @spec prune_bodies(Path.t(), Date.t(), limits()) :: report()
  def prune_bodies(trace_dir, %Date{} = today, limits \\ limits())
      when is_binary(trace_dir) and is_map(limits) do
    case days(Path.expand(trace_dir)) do
      {:ok, days, _unlisted_named_by_prune} ->
        days
        |> Enum.filter(&bodies_due?(&1, today, limits))
        |> Enum.take(limits.max_removals)
        |> Enum.reduce(%{removed: [], refused: []}, &remove_bodies/2)
        |> then(&%{removed: Enum.reverse(&1.removed), refused: Enum.reverse(&1.refused)})

      {:error, _path, _reason_named_by_prune} ->
        %{removed: [], refused: []}
    end
  end

  defp bodies_due?(%{date: date, names: names}, today, limits) do
    age = Date.diff(today, date)

    age > limits.body_max_age_days and age <= limits.max_age_days and
      Enum.any?(names, &bodies_file?/1)
  end

  defp bodies_file?(name), do: String.ends_with?(name, @bodies_suffix)

  # The day counts as removed once each of its bodies files is gone; a file
  # gone since the listing is the outcome the removal was after.
  defp remove_bodies(%{date: date, path: path, names: names}, report) do
    refused =
      names
      |> Enum.filter(&bodies_file?/1)
      |> Enum.map(&Path.join(path, &1))
      |> Enum.flat_map(&remove_file/1)

    case refused do
      [] -> %{report | removed: [date | report.removed]}
      _some -> %{report | refused: Enum.reverse(refused) ++ report.refused}
    end
  end

  defp remove_file(file) do
    case File.rm(file) do
      :ok -> []
      {:error, :enoent} -> []
      {:error, reason} -> [{file, reason}]
    end
  end

  defp days("/"), do: {:error, "/", :unsafe_trace_dir}

  defp days(base) do
    case File.ls(base) do
      {:ok, names} ->
        {days, unseen} = names |> Enum.flat_map(&day(base, &1)) |> Enum.split_with(&is_map/1)
        {:ok, Enum.sort_by(days, & &1.date, Date), unseen}

      {:error, :enoent} ->
        {:ok, [], []}

      {:error, reason} ->
        {:error, base, reason}
    end
  end

  # A day of traces is named exactly as an ISO date. Anything else is not the
  # store's and is left alone.
  defp day(base, name) do
    with {:ok, date} <- Date.from_iso8601(name),
         true <- Date.to_iso8601(date) == name do
      trace_day(Path.join(base, name), date)
    else
      _not_a_day -> []
    end
  end

  # A directory, never a link, holding what `Trace` writes and nothing else
  # but hidden files. An entry named as a day that cannot be looked at is
  # refused, so a day it cannot see is never silent.
  defp trace_day(path, date) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, names} <- File.ls(path) do
      case Enum.all?(names, &(String.ends_with?(&1, ".jsonl") or String.starts_with?(&1, "."))) do
        true -> [%{date: date, path: path, names: Enum.sort(names)}]
        false -> []
      end
    else
      {:ok, %File.Stat{}} -> []
      {:error, :enoent} -> []
      {:error, reason} -> [{path, reason}]
    end
  end

  defp plan(days, today, limits) do
    {expired, live} = Enum.split_with(days, &(Date.diff(today, &1.date) > limits.max_age_days))
    {oversize, refused} = over_size(live, today, limits.max_bytes)
    {Enum.take(expired ++ oversize, limits.max_removals), refused}
  end

  # The oldest days before today that must go for every day left, today and
  # any later day included, to fit in `max_bytes`; none while a day cannot be
  # sized, since the total is then unknown.
  defp over_size(live, today, max_bytes) do
    sized = Enum.map(live, &Map.put(&1, :bytes, day_bytes(&1.path)))

    case for(%{path: path, bytes: {:error, reason}} <- sized, do: {path, reason}) do
      [] -> {oldest_until_fits(sized, today, max_bytes), []}
      unsized -> {[], unsized}
    end
  end

  defp oldest_until_fits(sized, today, max_bytes) do
    total = Enum.sum(for %{bytes: {:ok, bytes}} <- sized, do: bytes)

    sized
    |> Enum.filter(&(Date.compare(&1.date, today) == :lt))
    |> Enum.reduce_while({total, []}, fn %{bytes: {:ok, bytes}} = day, {left, oversize} ->
      if left > max_bytes,
        do: {:cont, {left - bytes, [day | oversize]}},
        else: {:halt, {left, oversize}}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # The bytes of the files directly in a day folder, where `Trace` writes.
  defp day_bytes(path) do
    with {:ok, names} <- File.ls(path) do
      Enum.reduce_while(names, {:ok, 0}, &add_file_bytes(path, &1, &2))
    end
  end

  # A file gone since the listing holds nothing; anything but a regular file
  # is not one `Trace` wrote.
  defp add_file_bytes(dir, name, {:ok, sum}) do
    case File.lstat(Path.join(dir, name)) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:cont, {:ok, sum + size}}
      {:ok, %File.Stat{}} -> {:cont, {:ok, sum}}
      {:error, :enoent} -> {:cont, {:ok, sum}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp remove({doomed, refused}, today, unseen) do
    report = %{removed: [], refused: Enum.reverse(unseen ++ refused)}

    doomed
    |> Enum.reduce(report, &remove_day(&1, today, &2))
    |> then(&%{removed: Enum.reverse(&1.removed), refused: Enum.reverse(&1.refused)})
  end

  # Today's folder holds the files `Trace` has open: refused here by name,
  # whatever the plan says.
  defp remove_day(%{date: date, path: path}, today, report) do
    with :lt <- Date.compare(date, today),
         {:ok, _removed} <- File.rm_rf(path) do
      %{report | removed: [date | report.removed]}
    else
      {:error, reason, file} -> %{report | refused: [{file, reason} | report.refused]}
      _today_or_later -> %{report | refused: [{path, :not_before_today} | report.refused]}
    end
  end
end
