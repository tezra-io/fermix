defmodule FermixCore.Cues.Counts do
  @moduledoc """
  What a stream's intake counts instead of storing (M60_CUE_INTAKE_AT_SCALE.md
  §3.4), kept in memory by the process that counts it: per source by
  `Cues.Source.Stream`, per watcher by `Cues.LiveFilters`. Pure: the owner adds
  to it, writes `rows/1` with `CuesSql`'s `{:counts_put, rows, now}`, says what
  was written with `written/3`, and traces with `report/1`.

  A row is one ref's absolute totals for one UTC hour and this incarnation (a
  fresh random id per process start), and a flush replaces it, so a flush that
  timed out, still ran and is sent again cannot count twice. An hour that has
  passed is kept until a flush wrote it; the current one stays, since it still
  grows. A crash loses what was counted since the last flush.

  The count names are fixed per scope:

    * `"source"`: `received`, `unmatched` (no watcher's words matched),
      `rate_limited`, `over_budget`, `invalid`, `stale`;
    * `"watcher"`: `offered`, `overflow` (its live queue was full),
      `over_budget` (its filter budget was spent), `dropped`, `filter_failed`,
      `write_failed`, `passed`.

  Each `report/1` emits one `Cues.Telemetry` lifecycle event per count with
  what it gained since the last report, under its lifecycle phase (`invalid`
  is `rejected`). `received`, `offered` and `passed` are not reported: the
  first two are no outcome, and a pass has its own events.
  """

  alias FermixCore.Cues.Telemetry
  alias FermixCore.Memory.Repo.CuesSql

  @names %{
    "source" => ~w(received unmatched rate_limited over_budget invalid stale),
    "watcher" => ~w(offered overflow over_budget dropped filter_failed write_failed passed)
  }
  @phases %{
    "unmatched" => :unmatched,
    "rate_limited" => :rate_limited,
    "over_budget" => :over_budget,
    "invalid" => :rejected,
    "stale" => :stale,
    "overflow" => :overflow,
    "dropped" => :dropped,
    "filter_failed" => :filter_failed,
    "write_failed" => :write_failed
  }
  @ref_keys %{"source" => :source_ref, "watcher" => :watcher_id}

  @type scope :: String.t()
  @type t :: %{
          scope: scope(),
          incarnation: String.t(),
          totals: %{optional({String.t(), DateTime.t()}) => %{String.t() => pos_integer()}},
          unreported: %{optional({String.t(), String.t()}) => pos_integer()}
        }

  @doc "Empty counts of `scope`, `source` or `watcher`, with a new incarnation."
  @spec new(scope()) :: t()
  def new(scope) when is_map_key(@names, scope) do
    incarnation = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    %{scope: scope, incarnation: incarnation, totals: %{}, unreported: %{}}
  end

  @doc "Adds `n` to `ref`'s count `name` in `now`'s hour."
  @spec add(t(), String.t(), String.t(), non_neg_integer(), DateTime.t()) :: t()
  def add(counts, _ref, _name, 0, %DateTime{}), do: counts

  def add(%{scope: scope} = counts, ref, name, n, %DateTime{} = now)
      when is_binary(ref) and is_integer(n) and n > 0 do
    true = name in Map.fetch!(@names, scope)
    key = {ref, CuesSql.hour_of(now)}

    totals =
      Map.update(counts.totals, key, %{name => n}, &Map.update(&1, name, n, fn t -> t + n end))

    unreported = Map.update(counts.unreported, {ref, name}, n, &(&1 + n))
    %{counts | totals: totals, unreported: unreported}
  end

  @doc "The rows a flush writes: every hour still kept, as absolute totals."
  @spec rows(t()) :: [map()]
  def rows(counts) do
    for {{ref, hour}, totals} <- counts.totals do
      %{
        scope: counts.scope,
        ref: ref,
        hour: hour,
        incarnation: counts.incarnation,
        counts: totals
      }
    end
  end

  @doc """
  Forgets the hours before `now`'s that `rows` wrote with the totals still
  held: they can grow no more.
  """
  @spec written(t(), [map()], DateTime.t()) :: t()
  def written(counts, rows, %DateTime{} = now) when is_list(rows) do
    current = CuesSql.hour_of(now)

    totals =
      Enum.reduce(rows, counts.totals, fn row, acc ->
        key = {row.ref, row.hour}

        if DateTime.compare(row.hour, current) == :lt and Map.get(acc, key) == row.counts,
          do: Map.delete(acc, key),
          else: acc
      end)

    %{counts | totals: totals}
  end

  @doc "Emits one lifecycle event per count gained since the last report, and clears them."
  @spec report(t()) :: t()
  def report(counts) do
    ref_key = Map.fetch!(@ref_keys, counts.scope)

    for {{ref, name}, n} <- counts.unreported, phase = Map.get(@phases, name) do
      Telemetry.lifecycle(phase, %{count: n}, %{ref_key => ref})
    end

    %{counts | unreported: %{}}
  end
end
