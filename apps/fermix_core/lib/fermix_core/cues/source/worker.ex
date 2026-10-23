defmodule FermixCore.Cues.Source.Worker do
  @moduledoc """
  The plumbing `Cues.Source.Feed` and `Cues.Source.Stream` share (M60 §6):
  plain functions over a worker's state map, which holds at least the fields
  `base_state/1` builds from the start options: `source` (a
  `Cues.Config.sources/0` map), `repo`, `clock`, `monotonic_ms`, `schedule`,
  `admit`, `notify`, `timers`, `next_token`, `loaded?`, `last_good_at`,
  `paused_day` and `budget_notified`.

  Row reads and writes go through `repo_call/2`, which traces a failure
  (`ingest_error`) and logs it before returning it; source events go through
  `trace/3` (`Cues.Telemetry.source/2`, with the source's kind); timers carry a
  token (`schedule/3`), so a stale one is ignored.
  """

  require Logger

  alias FermixCore.Cues.Buckets
  alias FermixCore.Cues.Item
  alias FermixCore.Cues.Notices
  alias FermixCore.Cues.Telemetry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql

  # A retry delay doubles at most this many times before its cap.
  @max_retry_shift 6
  # A day's budget pause ends this long after UTC midnight.
  @after_midnight_ms 1_000

  @typedoc "A worker's state: the shared fields below plus the worker's own."
  @type state :: map()

  @doc """
  The shared fields of a worker's state, from its start options (`:source`
  required; `:repo`, `:clock`, `:monotonic_ms`, `:schedule`, `:admit`,
  `:notify`, each with its production default), and the link to `:manager`
  (`Cues.SourceManager` passes itself), made here so the manager sees the
  worker's exit with its reason however soon it comes.
  """
  @spec base_state(keyword()) :: state()
  def base_state(opts) when is_list(opts) do
    %{ref: ref, kind: kind} = source = Keyword.fetch!(opts, :source)
    true = is_binary(ref) and kind in [:feed, :stream]
    link_manager(Keyword.get(opts, :manager))

    %{
      source: source,
      repo: Keyword.get(opts, :repo, Repo),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      monotonic_ms:
        Keyword.get(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
      schedule: Keyword.get(opts, :schedule, &send_after/2),
      admit: Keyword.get(opts, :admit, &Buckets.admit/3),
      notify: Keyword.get(opts, :notify, &Notices.source/4),
      timers: %{},
      next_token: 0,
      loaded?: false,
      last_good_at: nil,
      paused_day: nil,
      budget_notified: nil
    }
  end

  # --- timers ------------------------------------------------------------------------

  @doc "Arms timer `kind` after `ms`; a later `schedule/3` of the same kind replaces it."
  @spec schedule(state(), atom(), non_neg_integer()) :: state()
  def schedule(state, kind, ms) when is_atom(kind) and is_integer(ms) and ms >= 0 do
    token = state.next_token + 1
    state.schedule.({:timer, kind, token}, ms)
    %{state | next_token: token, timers: Map.put(state.timers, kind, token)}
  end

  @doc "Forgets timer `kind`, so its message is ignored when it comes."
  @spec drop_timer(state(), atom()) :: state()
  def drop_timer(state, kind) when is_atom(kind),
    do: %{state | timers: Map.delete(state.timers, kind)}

  @doc """
  Takes timer `kind` if `token` is its current one: `{:due, state}` with the
  timer forgotten, or `:stale`.
  """
  @spec take_timer(state(), atom(), pos_integer()) :: {:due, state()} | :stale
  def take_timer(state, kind, token) do
    if Map.get(state.timers, kind) == token,
      do: {:due, drop_timer(state, kind)},
      else: :stale
  end

  @doc "The retry delay after `failures` in a row: `first_ms` doubling up to `max_ms`."
  @spec backoff_ms(pos_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def backoff_ms(failures, first_ms, max_ms) when is_integer(failures) and failures > 0 do
    shift = min(failures - 1, @max_retry_shift)
    min(first_ms * Integer.pow(2, shift), max_ms)
  end

  # --- the source's row ----------------------------------------------------------------

  @doc """
  Reads the source's row once: `{:ok, state, row | nil}` with `loaded?`,
  `last_good_at` and the day's budget pause taken from it (a source whose
  budget is spent today stays paused); a state already loaded comes back with
  no row. The worker reads its own fields (a feed's cursor) from the row.
  """
  @spec load(state(), DateTime.t()) :: {:ok, state(), map() | nil} | {:error, term()}
  def load(%{loaded?: true} = state, _now), do: {:ok, state, nil}

  def load(state, now) do
    case repo_call(state, {:get_source, state.source.ref}) do
      {:ok, nil} -> {:ok, %{state | loaded?: true}, nil}
      {:ok, row} -> {:ok, from_row(state, row, now), row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp from_row(state, row, now) do
    today = utc_date(now)
    spent? = row.status == "over_budget" and row.items_day == Date.to_iso8601(today)

    %{
      state
      | loaded?: true,
        last_good_at: row.last_good_at,
        paused_day: if(spent?, do: today),
        budget_notified: if(spent?, do: today)
    }
  end

  @doc "Writes `attrs` to the source's row (`{:source_touch, …}`)."
  @spec touch(state(), map(), DateTime.t()) :: term()
  def touch(state, attrs, now),
    do: repo_call(state, {:source_touch, state.source.ref, attrs, now})

  @doc """
  Extends the source's open gap of `reason` by `count` over `range` and traces
  it. A gap that cannot be written is traced and logged by `repo_call/2`.
  """
  @spec gap(state(), String.t(), pos_integer(), term(), DateTime.t()) :: term()
  def gap(state, reason, count, range, now) do
    request = {:extend_gap, state.source.ref, nil, reason, count, range, now}

    with {:ok, _gap_id} <- repo_call(state, request) do
      trace(state, :gap, %{reason: reason, count: count})
    end
  end

  @doc "One `CuesSql` request; a failure is traced and logged here, then returned."
  @spec repo_call(state(), tuple()) :: term()
  def repo_call(state, request) do
    case Repo.cues_call(CuesSql, request, server: state.repo) do
      {:error, reason} ->
        Telemetry.lifecycle(:ingest_error, %{}, %{
          source_ref: state.source.ref,
          result: {:error, reason}
        })

        Logger.warning("#{label(state)}: #{elem(request, 0)} failed: #{inspect(reason)}")
        {:error, reason}

      result ->
        result
    end
  end

  # --- budget ----------------------------------------------------------------------------

  @doc """
  The daily budget is spent: traced, the owner told once that UTC day
  (`:budget_reached`), and the worker paused for the rest of it.
  """
  @spec budget_reached(state(), DateTime.t()) :: state()
  def budget_reached(state, now) do
    day = utc_date(now)
    trace(state, :budget, %{status: "over_budget"})

    if state.budget_notified != day,
      do: notify(state, :budget_reached, %{budget: state.source.daily_budget}, now)

    %{state | paused_day: day, budget_notified: day}
  end

  @doc "Whether the worker's budget pause covers `now`'s UTC day."
  @spec paused?(state(), DateTime.t()) :: boolean()
  def paused?(state, now), do: state.paused_day == utc_date(now)

  @doc "Milliseconds from `now` to just after the next UTC midnight."
  @spec ms_to_next_day(DateTime.t()) :: pos_integer()
  def ms_to_next_day(now) do
    midnight = DateTime.new!(Date.add(utc_date(now), 1), ~T[00:00:00], "Etc/UTC")
    DateTime.diff(midnight, now, :millisecond) + @after_midnight_ms
  end

  @doc "The UTC date of `now`."
  @spec utc_date(DateTime.t()) :: Date.t()
  def utc_date(now), do: now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date()

  # --- ingest ----------------------------------------------------------------------------

  @doc "The source as `Cues.Ingest.accept/3` takes it."
  @spec ingest_source(state()) :: FermixCore.Cues.Ingest.source()
  def ingest_source(state), do: %{ref: state.source.ref, daily_budget: state.source.daily_budget}

  @doc "The `:admit` function `Cues.Ingest.accept/3` takes: the source's rate buckets."
  @spec admit_fun(state()) :: (pos_integer() -> non_neg_integer())
  def admit_fun(state) do
    ref = state.source.ref
    fn n -> state.admit.(ref, n, state.monotonic_ms.()) end
  end

  @doc "An `Item.new/2` result as an ingest entry: the item, or its refusal."
  @spec unwrap({:ok, Item.t()} | {:error, term()}) :: Item.t() | {:error, term()}
  def unwrap({:ok, item}), do: item
  def unwrap({:error, _refusal} = refused), do: refused

  # --- notices and traces ------------------------------------------------------------------

  @doc "Sends source notice `kind`; a failed send is logged (`Cues.Notices` keeps it once)."
  @spec notify(state(), atom(), map(), DateTime.t()) :: :ok
  def notify(state, kind, data, now) do
    case state.notify.(state.source.ref, kind, data, repo: state.repo, now: now) do
      {:error, reason} ->
        Logger.error("#{label(state)}: the #{kind} notice failed: #{inspect(reason)}")

      _sent ->
        :ok
    end
  end

  @doc "A source event (`Cues.Telemetry.source/2`) with the source's ref and kind."
  @spec trace(state(), atom(), map()) :: :ok
  def trace(state, phase, metadata) do
    base = %{source_ref: state.source.ref, kind: state.source.kind}
    Telemetry.source(phase, Map.merge(base, metadata))
  end

  @doc "How the worker names itself in the log: `Cue feed <ref>` or `Cue stream <ref>`."
  @spec label(state()) :: String.t()
  def label(%{source: %{kind: kind, ref: ref}}), do: "Cue #{kind} #{ref}"

  # --- private -----------------------------------------------------------------------------

  defp send_after(message, ms), do: Process.send_after(self(), message, ms)

  defp link_manager(nil), do: :ok
  defp link_manager(manager) when is_pid(manager), do: Process.link(manager)
end
