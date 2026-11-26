# When each seeded job run happened (bin/seed_state.exs), worked out before anything is
# written, from `now` passed in, so the rule is pure and bin/seed_run_times_test.exs
# can check it at any instant.
#
# A scheduled run of a cron job runs at the job's own fire time: `fires_ago: n` is the
# nth most recent fire of the job's schedule, in the job's zone, through the engine's
# own schedule parser (`Jobs.Schedule`). An off-schedule run is stated as one:
# `hours_ago` hours before now, for a `manual` run. Each run lasts `duration_seconds`,
# and a heal concluded on it (`heal`) is concluded `delivered_minutes_after` minutes
# after the run ended (and its message sent then), or `decided_minutes_after` minutes
# after (its send left to the daemon). The fires counted are those early enough that
# every run and conclusion of the job ends before now, so a seed taken right after a
# fire still finds every run over.
defmodule SeedRunTimes do
  alias FermixCore.Jobs.Schedule

  # The first look-back window and how many times it doubles (2^16 hours is over seven
  # years), the fire times one window may step through, and the gap left before now.
  @first_window_s 3_600
  @max_windows 16
  @max_steps 2_000
  @margin_s 60

  @doc """
  Each run's start, in the spec's order, or a raise naming the job. Every run states
  exactly one of `fires_ago` (a positive whole number, a `schedule` run of a cron job)
  or `hours_ago` (a whole number, a `manual` run), and a whole `duration_seconds`.
  """
  def starts!(%{} = job, zone, %DateTime{} = now) when is_binary(zone) do
    key = Map.get(job, "key")
    runs = Map.get(job, "runs", [])
    Enum.each(runs, &check_when!(key, &1))
    fires = fires!(key, Map.fetch!(job, "schedule"), zone, cutoff(runs, now), deepest(runs))
    Enum.map(runs, &start(&1, fires, now))
  end

  @doc "When a run ended."
  def ended(%{"duration_seconds" => seconds}, %DateTime{} = start),
    do: DateTime.add(start, seconds, :second)

  @doc "When a heal concluded on a run was concluded: minutes after the run ended."
  def concluded(%{"heal" => heal} = run, start),
    do: DateTime.add(ended(run, start), conclusion_minutes(heal) * 60, :second)

  @doc """
  The minutes after its run a seeded heal was concluded: `delivered_minutes_after` (its
  message sent then) or `decided_minutes_after` (its send left to the daemon), whichever
  it names; `check_order!/4`'s checks made sure it names exactly one.
  """
  def conclusion_minutes(%{"delivered_minutes_after" => minutes}), do: minutes
  def conclusion_minutes(%{"decided_minutes_after" => minutes}), do: minutes

  @doc """
  The runs in time order, as listed: each starts after the one before ended, every run
  and conclusion ends before now, and a conclusion comes before the next run starts.
  """
  def check_order!(key, runs, starts, %DateTime{} = now) do
    ends = Enum.zip_with(runs, starts, &last_moment/2)
    nexts = Enum.drop(starts, 1) ++ [now]

    overrun = Enum.find(Enum.zip(ends, nexts), fn {done, next} -> not before?(done, next) end)

    case overrun do
      nil ->
        :ok

      {done, next} ->
        raise "jobs #{key}: runs are listed oldest first, each (and any conclusion on it) " <>
                "over before the next starts and before now; one ends at " <>
                "#{DateTime.to_iso8601(done)}, at or after #{DateTime.to_iso8601(next)}"
    end
  end

  defp before?(earlier, later), do: DateTime.compare(earlier, later) == :lt

  # The run's end, or its heal's conclusion when one is seeded on it.
  defp last_moment(%{"heal" => _heal} = run, start), do: concluded(run, start)
  defp last_moment(run, start), do: ended(run, start)

  defp check_when!(key, run) do
    unless count?(Map.get(run, "duration_seconds")),
      do: raise("jobs #{key}: a run's duration_seconds is a whole number, got #{inspect(run)}")

    check_conclusion_delay!(key, Map.get(run, "heal"))
    check_moment!(key, Map.get(run, "trigger", "schedule"), run)
  end

  defp check_conclusion_delay!(_key, nil), do: :ok

  defp check_conclusion_delay!(key, heal) do
    named = Map.take(heal, ["delivered_minutes_after", "decided_minutes_after"])

    unless map_size(named) == 1 and Enum.all?(Map.values(named), &positive?/1),
      do:
        raise(
          "jobs #{key}: a seeded heal names one of delivered_minutes_after (sent then) or decided_minutes_after (its send left to the daemon), a positive whole number of minutes after its run ended, got #{inspect(named)}"
        )
  end

  defp check_moment!(key, "schedule", run) do
    unless positive?(Map.get(run, "fires_ago")) and not Map.has_key?(run, "hours_ago"),
      do:
        raise(
          "jobs #{key}: a scheduled run runs at its job's fire time: state fires_ago (1 for the most recent), not hours_ago, got #{inspect(run)}"
        )
  end

  defp check_moment!(key, "manual", run) do
    unless count?(Map.get(run, "hours_ago")) and not Map.has_key?(run, "fires_ago"),
      do:
        raise(
          "jobs #{key}: a manual run is off schedule: state hours_ago, not fires_ago, got #{inspect(run)}"
        )
  end

  defp check_moment!(key, trigger, _run),
    do: raise("jobs #{key}: no timing rule for a #{inspect(trigger)} run")

  defp count?(value), do: is_integer(value) and value >= 0
  defp positive?(value), do: is_integer(value) and value > 0

  defp start(%{"fires_ago" => n}, fires, _now), do: Enum.at(fires, n - 1)
  defp start(%{"hours_ago" => hours}, _fires, now), do: DateTime.add(now, -hours * 3_600, :second)

  # Late enough that the job's longest run, with any conclusion on it, ends before now.
  defp cutoff(runs, now) do
    tail = runs |> Enum.map(&tail_s/1) |> Enum.max(fn -> 0 end)
    DateTime.add(now, -(tail + @margin_s), :second)
  end

  defp tail_s(%{"heal" => heal} = run),
    do: run["duration_seconds"] + conclusion_minutes(heal) * 60

  defp tail_s(run), do: run["duration_seconds"]

  defp deepest(runs), do: runs |> Enum.map(&Map.get(&1, "fires_ago", 0)) |> Enum.max(fn -> 0 end)

  # The schedule's `n` most recent fire times at or before `cutoff`, newest first.
  defp fires!(_key, _expr, _zone, _cutoff, 0), do: []

  defp fires!(key, expr, zone, cutoff, n) do
    case Schedule.parse(expr, timezone: zone, now: cutoff) do
      {:ok, %{kind: "cron"}} ->
        look_back!(key, expr, zone, cutoff, n, @first_window_s, @max_windows)

      other ->
        raise "jobs #{key}: fires_ago needs a cron schedule, and #{inspect(expr)} gives #{inspect(other)}"
    end
  end

  defp look_back!(key, expr, _zone, _cutoff, n, _window_s, 0),
    do: raise("jobs #{key}: #{inspect(expr)} has no #{n} fire times within the look-back")

  defp look_back!(key, expr, zone, cutoff, n, window_s, windows_left) do
    from = DateTime.add(cutoff, -window_s, :second)
    fires = fires_between!(key, expr, zone, from, cutoff, [], @max_steps)

    if length(fires) >= n,
      do: Enum.take(fires, n),
      else: look_back!(key, expr, zone, cutoff, n, window_s * 2, windows_left - 1)
  end

  # Each fire after `from` and at or before `cutoff`, newest first.
  defp fires_between!(key, expr, _zone, _from, _cutoff, _acc, 0),
    do: raise("jobs #{key}: #{inspect(expr)} fires more than #{@max_steps} times in one window")

  defp fires_between!(key, expr, zone, from, cutoff, acc, steps_left) do
    {:ok, %{next_run_at: next}} = Schedule.parse(expr, timezone: zone, now: from)

    if DateTime.compare(next, cutoff) == :gt,
      do: acc,
      else: fires_between!(key, expr, zone, next, cutoff, [next | acc], steps_left - 1)
  end
end
