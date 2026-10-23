defmodule FermixCore.OpenLoops.ActiveHours do
  @moduledoc """
  The owner's active hours, derived from their own messages (MILESTONE_78 §06).

  There is no quiet-hours setting anywhere in Fermix, and this adds none. The
  window is read from the owner's own user chat messages over the last 28 days,
  guest rows excluded as the memory reviewer excludes them: the 15th to 85th
  percentile hour of day in the loop's zone, widened around its middle to at
  least six hours and never past midnight. With fewer than 40 messages it is
  09:00 to 21:00 local. One resolver; its result is snapshotted into a check-in's
  start event (`label/1`) so a mistimed check-in can be read back.

  A window is `start <= time < finish` in local wall-clock time, both whole
  hours of one day.
  """

  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.Defaults

  @type hours :: %{
          start: Time.t(),
          finish: Time.t(),
          source: :derived | :default,
          sample: non_neg_integer()
        }

  @last_hour 23

  @doc """
  Resolves the window for one owner in `zone` from the Repo `repo_opts` names.
  """
  @spec resolve(keyword(), String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, hours()} | {:error, term()}
  def resolve(repo_opts, agent_id, owner_id, zone, %DateTime{} = now)
      when is_list(repo_opts) and is_binary(agent_id) and is_binary(owner_id) and is_binary(zone) do
    since = DateTime.add(now, -Defaults.active_hours_lookback_days() * 86_400, :second)

    with {:ok, instants} <- Repo.owner_message_hours(agent_id, owner_id, since, repo_opts) do
      {:ok, derive(instants, zone)}
    end
  end

  @doc "The window a set of message instants gives in `zone` (pure)."
  @spec derive([DateTime.t()], String.t()) :: hours()
  def derive(instants, zone) when is_list(instants) and is_binary(zone) do
    sample = length(instants)

    if sample < Defaults.active_hours_min_messages() do
      {start, finish} = Defaults.active_hours_default()
      %{start: start, finish: finish, source: :default, sample: sample}
    else
      instants |> Enum.map(&local_hour(&1, zone)) |> Enum.sort() |> window(sample)
    end
  end

  defp window(hours, sample) do
    {low, high} = Defaults.active_hours_percentiles()
    {start, finish} = widen(percentile(hours, sample, low), percentile(hours, sample, high))

    %{
      start: Time.new!(start, 0, 0),
      finish: Time.new!(finish, 0, 0),
      source: :derived,
      sample: sample
    }
  end

  # Nearest rank: the smallest value with at least `p` percent of the sample at
  # or below it.
  defp percentile(sorted, sample, p) do
    Enum.at(sorted, max(ceil(p * sample / 100) - 1, 0))
  end

  defp widen(start, finish) do
    deficit = max(Defaults.active_hours_min_span_hours() - (finish - start), 0)
    early = div(deficit, 2)
    clamp(start - early, finish + deficit - early)
  end

  defp clamp(start, finish) when start < 0, do: clamp(0, finish - start)

  defp clamp(start, finish) when finish > @last_hour,
    do: {start - (finish - @last_hour), @last_hour}

  defp clamp(start, finish), do: {start, finish}

  defp local_hour(at, zone), do: DateTime.shift_zone!(at, zone).hour

  @doc "Whether `at` falls inside the window, read in `zone`."
  @spec inside?(hours(), DateTime.t(), String.t()) :: boolean()
  def inside?(%{start: start, finish: finish}, %DateTime{} = at, zone) when is_binary(zone) do
    time = at |> DateTime.shift_zone!(zone) |> DateTime.to_time()
    Time.compare(time, start) != :lt and Time.compare(time, finish) == :lt
  end

  @doc "The first active-hours start strictly after `at`, as a UTC instant."
  @spec next_start(hours(), DateTime.t(), String.t()) :: DateTime.t()
  def next_start(%{start: _start} = hours, %DateTime{} = at, zone) when is_binary(zone) do
    today = at |> DateTime.shift_zone!(zone) |> DateTime.to_date()
    candidate = start_on(hours, today, zone)

    if DateTime.compare(candidate, at) == :gt,
      do: candidate,
      else: start_on(hours, Date.add(today, 1), zone)
  end

  @doc """
  The start of the local day `at` falls in, as a UTC instant: the day the
  owner's rung 2 budget is counted over, in the loop's zone.
  """
  @spec day_start(DateTime.t(), String.t()) :: DateTime.t()
  def day_start(%DateTime{} = at, zone) when is_binary(zone) do
    today = at |> DateTime.shift_zone!(zone) |> DateTime.to_date()
    local_instant(today, ~T[00:00:00], zone)
  end

  @doc "The window's start on one local date, as a UTC instant."
  @spec start_on(hours(), Date.t(), String.t()) :: DateTime.t()
  def start_on(%{start: start}, %Date{} = date, zone) when is_binary(zone) do
    local_instant(date, start, zone)
  end

  @doc """
  A local wall time as a UTC instant. A time inside a DST gap becomes the first
  instant after the gap; a time in a fold is its first occurrence, as
  `Temporal.Planner` reads a day start.
  """
  @spec local_instant(Date.t(), Time.t(), String.t()) :: DateTime.t()
  def local_instant(%Date{} = date, %Time{} = time, zone) when is_binary(zone) do
    case DateTime.new(date, time, zone) do
      {:ok, local} ->
        DateTime.shift_zone!(local, "Etc/UTC")

      {:ambiguous, first, _second} ->
        DateTime.shift_zone!(first, "Etc/UTC")

      {:gap, _before, after_gap} ->
        DateTime.shift_zone!(after_gap, "Etc/UTC")

      {:error, reason} ->
        raise ArgumentError, "cannot place #{date} #{time} in #{zone}: #{reason}"
    end
  end

  @doc "The window as `HH:MM-HH:MM`, for the trace."
  @spec label(%{start: Time.t(), finish: Time.t()}) :: String.t()
  def label(%{start: %Time{} = start, finish: %Time{} = finish}) do
    Calendar.strftime(start, "%H:%M") <> "-" <> Calendar.strftime(finish, "%H:%M")
  end
end
